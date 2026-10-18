using System.Collections.Concurrent;
using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading.Channels;
using Org.BouncyCastle.Tls;

namespace Nocturne.Host;

public interface IWorkspaceFiles : IDisposable
{
    RemoteFile[] List(string path);
    (byte[] Data, long Size, bool Eof) Read(string path, long offset);
    IUpload BeginUpload(string path, long size);
}

public interface IUpload : IDisposable
{
    string Id { get; }
    long Received { get; }
    void Append(byte[] data, long offset);
    void Commit();
}

public sealed class WorkspaceServer : IAsyncDisposable
{
    private readonly string name;
    private readonly byte[] secret;
    private readonly DeviceStore devices;
    private readonly IWorkspaceFiles? files;
    private readonly IStreamingEngine? engine;
    private readonly TerminalRegistry terminals;
    private readonly ConcurrentDictionary<Guid, Session> sessions = [];
    private readonly SemaphoreSlim identityChanges = new(1);
    private readonly object permissionGate = new();
    private readonly CancellationTokenSource stopped = new();
    private readonly ConcurrentDictionary<Guid, Task> tasks = [];
    private TcpListener? listener;
    private Task? acceptTask;
    private HostPermissions permissions;
    public event Action? DevicesChanged;
    public event Action<string>? SessionError;
    public string[] ConnectedDevices => sessions.Values.Select(s => s.Identity).OfType<string>().Distinct().ToArray();
    public int Port => ((IPEndPoint)(listener?.LocalEndpoint ?? throw new IOException("Server is stopped."))).Port;

    public WorkspaceServer(string name, byte[] secret, DeviceStore devices, HostPermissions permissions,
        IWorkspaceFiles? files, Func<int, int, ITerminal> terminalFactory, IStreamingEngine? engine = null)
    {
        if (secret.Length != 32) throw new ArgumentException("The workspace key must contain 32 bytes.");
        this.name = name; this.secret = (byte[])secret.Clone(); this.devices = devices;
        this.permissions = permissions; this.files = files; this.engine = engine;
        terminals = new(terminalFactory);
    }

    public void Start(int port = Wire.Port, IPAddress? address = null)
    {
        if (listener != null || stopped.IsCancellationRequested) throw new InvalidOperationException("Create a new server to start again.");
        listener = new(address ?? IPAddress.IPv6Any, port);
        if (address == null) listener.Server.DualMode = true;
        listener.Server.ExclusiveAddressUse = true;
        listener.Start(8);
        acceptTask = AcceptAsync();
    }

    private async Task AcceptAsync()
    {
        try
        {
            while (!stopped.IsCancellationRequested)
            {
                var client = await listener!.AcceptTcpClientAsync(stopped.Token);
                if (sessions.Count >= 8) { client.Dispose(); continue; }
                client.NoDelay = true;
                client.ReceiveTimeout = 12_000; client.SendTimeout = 15_000;
                var id = Guid.NewGuid(); var session = new Session(this, id, client);
                sessions[id] = session;
                // Keep synchronous TLS reads off the UI and one bounded worker per connection.
                var task = Task.Run(() => session.Run()); tasks[id] = task;
                _ = task.ContinueWith(_ => { tasks.TryRemove(id, out var ignored); }, TaskScheduler.Default);
            }
        }
        catch (Exception ex) when (stopped.IsCancellationRequested && ex is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }

    public void UpdatePermissions(HostPermissions value)
    {
        lock (permissionGate)
        {
            Volatile.Write(ref permissions, value);
            if (!value.Terminal) terminals.CloseAll();
        }
        if (!value.Files) foreach (var session in sessions.Values) session.DiscardUploads();
    }

    public async Task RemoveDeviceAsync(string id, string name, CancellationToken cancellation = default)
    {
        lock (permissionGate)
        {
            devices.Block(id, name);
            foreach (var session in sessions.Values.Where(s => s.Identity == id)) { session.Close(); session.DiscardUploads(); }
            terminals.CloseAll(id);
        }
        DevicesChanged?.Invoke();
        await identityChanges.WaitAsync(cancellation);
        try
        {
            if (engine == null) throw new IOException("Start the server to finish removing this device's streaming access.");
            await engine.RemoveAsync(id, cancellation);
            devices.FinishRemoval(id);
        }
        finally { identityChanges.Release(); DevicesChanged?.Invoke(); }
    }

    public async ValueTask DisposeAsync()
    {
        stopped.Cancel(); listener?.Stop();
        foreach (var session in sessions.Values) session.Close();
        if (acceptTask != null) await acceptTask;
        try { await Task.WhenAll(tasks.Values.ToArray()); }
        finally
        {
            terminals.Dispose(); files?.Dispose();
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    private sealed class Session(WorkspaceServer server, Guid id, TcpClient client)
    {
        private sealed record Outbound(Packet Packet, TaskCompletionSource? Completion = null);
        private readonly Channel<Outbound> outgoing = Channel.CreateBounded<Outbound>(new BoundedChannelOptions(64)
        { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
        private readonly Dictionary<string, IUpload> uploads = [];
        private readonly object uploadGate = new();
        private int closed;
        private string? identity;
        public string? Identity => Volatile.Read(ref identity);
        private byte[]? nonce;
        private WorkspaceTlsServer? tls;
        private string deviceName = "Device";

        public void Run()
        {
            Task? writer = null;
            try
            {
                var protocol = new TlsServerProtocol(client.GetStream());
                tls = new(server.secret);
                protocol.Accept(tls);
                writer = Task.Run(() => WriteLoop(protocol.Stream));
                using var authDeadline = new Timer(_ => { if (Identity == null) Close(); }, null, 12_000, Timeout.Infinite);
                while (Volatile.Read(ref closed) == 0)
                {
                    var packet = Wire.Read(protocol.Stream);
                    try
                    {
                        var reply = Handle(packet);
                        if (reply != null) Send(reply);
                    }
                    catch (Exception ex) when (ex is IOException or ArgumentException or CryptographicException or UnauthorizedAccessException or Win32Exception or System.Runtime.InteropServices.COMException)
                    {
                        server.SessionError?.Invoke(packet.Operation + ": " + ex.Message);
                        var error = packet.Reply() with { Error = ex.Message };
                        if (packet.Operation is "hello" or "authenticate")
                        {
                            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                            if (outgoing.Writer.TryWrite(new(error, completion))) completion.Task.Wait(TimeSpan.FromSeconds(1));
                            break;
                        }
                        Send(error);
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
            { if (Volatile.Read(ref closed) == 0) server.SessionError?.Invoke(ex.GetType().Name + ": " + ex.Message); }
            finally
            {
                Close();
                writer?.GetAwaiter().GetResult();
                server.terminals.Detach(id); DiscardUploads();
                server.sessions.TryRemove(id, out _); server.DevicesChanged?.Invoke();
            }
        }

        private void WriteLoop(Stream stream)
        {
            try
            {
                while (outgoing.Reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
                    while (outgoing.Reader.TryRead(out var item))
                    {
                        stream.Write(Wire.Encode(item.Packet)); item.Completion?.TrySetResult();
                    }
            }
            catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException) { Close(); }
        }

        private void Send(Packet packet)
        {
            if (!outgoing.Writer.TryWrite(new(packet))) Close();
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            outgoing.Writer.TryComplete(); client.Dispose();
        }

        public void DiscardUploads()
        {
            lock (uploadGate)
            {
                foreach (var upload in uploads.Values)
                    try { upload.Dispose(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                uploads.Clear();
            }
        }

        private Packet? Handle(Packet packet)
        {
            var reply = packet.Reply();
            if (packet.Operation == "hello")
            {
                if (packet.Version != Wire.Version) throw new IOException("Update both Nocturne apps to the same protocol version.");
                if (nonce != null || Identity != null) throw new IOException("Invalid authentication sequence.");
                nonce = RandomNumberGenerator.GetBytes(32);
                reply.Version = Wire.Version; reply.Data = nonce; return reply;
            }
            if (packet.Operation == "authenticate")
            {
                if (Identity != null || nonce == null || packet.Certificate == null || packet.Signature == null || packet.Name == null)
                    throw new IOException("Invalid authentication sequence.");
                var challenge = tls!.BoundChallenge(nonce); nonce = null;
                var fingerprint = Wire.VerifyIdentity(packet.Certificate, packet.Signature, challenge);
                lock (server.permissionGate)
                {
                    var device = server.devices.Authorize(fingerprint, packet.Name, packet.EnrollmentToken);
                    deviceName = device.Name; Volatile.Write(ref identity, fingerprint);
                }
                client.ReceiveTimeout = 0;
                reply.Version = Wire.Version; reply.Name = server.name;
                var allowed = Volatile.Read(ref server.permissions);
                reply.Capabilities = new[] { allowed.Files && server.files != null ? "files" : null,
                    allowed.Terminal ? "terminal" : null, server.engine != null ? "streaming" : null }.OfType<string>().ToArray();
                server.DevicesChanged?.Invoke(); return reply;
            }
            var owner = Identity;
            if (owner == null || !server.devices.IsAuthorized(owner)) throw new IOException("Authenticate this device before using the computer.");
            var permissions = Volatile.Read(ref server.permissions);
            if (packet.Operation == "ping") return reply;
            if (packet.Operation == "pairStream")
            {
                var bytes = packet.Data;
                if (server.engine == null || bytes?.Length != 4 || bytes.Any(b => b is < 48 or > 57))
                    throw new IOException("Invalid streaming pairing request.");
                server.identityChanges.Wait(server.stopped.Token);
                try
                {
                    if (!server.devices.IsAuthorized(owner)) throw new IOException("This device has been removed.");
                    var address = ((IPEndPoint)client.Client.RemoteEndPoint!).Address;
                    server.engine.PairAsync(System.Text.Encoding.ASCII.GetString(bytes), deviceName,
                        address.MapToIPv6().IsIPv4MappedToIPv6 ? address.MapToIPv4().ToString() : address.ToString(), server.stopped.Token).GetAwaiter().GetResult();
                    if (!server.devices.IsAuthorized(owner)) throw new IOException("This device has been removed.");
                }
                finally { server.identityChanges.Release(); }
                return reply;
            }
            if (packet.Operation.StartsWith("terminal", StringComparison.Ordinal))
            {
                lock (server.permissionGate)
                {
                    if (!Volatile.Read(ref server.permissions).Terminal || !server.devices.IsAuthorized(owner))
                        throw new IOException("Enable Terminal in Nocturne Server, then reconnect.");
                    server.terminals.Handle(packet, owner, id, Send); return null;
                }
            }
            if (packet.Operation is "displayPrepare" or "displayHeartbeat" or "displayRelease" or "microphoneStart" or "microphoneAudio" or "microphoneStop")
                throw new IOException("This Windows host does not support display control or microphone forwarding. Choose a fixed video resolution in Settings.");
            lock (server.permissionGate)
            lock (uploadGate)
            {
                // Recheck within the same lock as permission-revocation cleanup.
                if (!server.devices.IsAuthorized(owner) || !Volatile.Read(ref server.permissions).Files || server.files == null)
                    throw new IOException("Enable File sharing in Nocturne Server, then reconnect.");
                switch (packet.Operation)
                {
                    case "list": reply.Files = server.files.List(packet.Path ?? ""); break;
                    case "read":
                        var chunk = server.files.Read(packet.Path ?? "", packet.Offset ?? 0);
                        reply.Data = chunk.Data; reply.Size = chunk.Size; reply.Eof = chunk.Eof; break;
                    case "uploadBegin":
                        if (uploads.Count >= 2) throw new IOException("Finish the current transfers first.");
                        var upload = server.files.BeginUpload(packet.Path ?? "", packet.Size ?? -1);
                        uploads[upload.Id] = upload; reply.TransferID = upload.Id; break;
                    case "uploadChunk":
                        var incoming = FindUpload(packet); incoming.Append(packet.Data ?? throw new IOException("Missing transfer data."), packet.Offset ?? -1);
                        reply.Offset = incoming.Received; break;
                    case "uploadCommit":
                        var ready = FindUpload(packet); ready.Commit(); ready.Dispose(); uploads.Remove(ready.Id); break;
                    case "uploadCancel":
                        if (packet.TransferID != null && uploads.Remove(packet.TransferID, out var cancelled)) cancelled.Dispose(); break;
                    default: throw new IOException("This Windows host does not support that feature. Use a fixed video resolution in Settings.");
                }
            }
            return reply;
        }

        private IUpload FindUpload(Packet packet) => packet.TransferID != null && uploads.TryGetValue(packet.TransferID, out var upload)
            ? upload : throw new IOException("The transfer is incomplete. Start it again.");
    }
}
