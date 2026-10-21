using System.Collections.Concurrent;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace Nocturne.Host;

public sealed record ClientInvitation(string Host, ushort Port, string Name, byte[] Secret, byte[]? EnrollmentToken = null, RemoteAccessInfo? RemoteAccess = null)
{
    public string Id => Wire.Fingerprint(Secret);
    public static ClientInvitation Parse(string code)
    {
        if (code.Length > 8192 || !Uri.TryCreate(code.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "nocturne" || uri.Host != "pair" ||
            uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath is not ("" or "/")) throw Invalid();
        try
        {
            var fields = uri.Query.TrimStart('?').Split('&').Select(part => part.Split('=', 2))
                .ToDictionary(part => Uri.UnescapeDataString(part[0]), part => part.Length == 2 ? Uri.UnescapeDataString(part[1]) : "");
            string Value(string key) => fields.TryGetValue(key, out var value) ? value : throw Invalid();
            var version = Value("v"); var host = Value("host");
            if (version is not ("1" or "2" or "3") || host.Length is 0 or > 253 || host.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || c is '/' or '\\' or '@') ||
                !ushort.TryParse(Value("port"), out var port) || port == 0) throw Invalid();
            var secret = Convert.FromBase64String(Value("key"));
            var token = fields.TryGetValue("token", out var encoded) ? Convert.FromBase64String(encoded) : null;
            if (secret.Length != 32 || version != "1" && token?.Length != 32 || token != null && token.Length != 32) throw Invalid();
            RemoteAccessInfo? remote = null;
            if (version == "3")
            {
                var endpoint = Value("endpoint");
                if (endpoint.Length != 64 || !endpoint.All(char.IsAsciiHexDigit)) throw Invalid();
                remote = new(RemoteAccessInfo.ValidateBroker(Value("broker")), endpoint.ToLowerInvariant());
            }
            var name = fields.GetValueOrDefault("name", host);
            if (name.Length is 0 or > 128 || name.Any(char.IsControl)) throw Invalid();
            return new(host, port, name, secret, token, remote);
        }
        catch (Exception error) when (error is ArgumentException or FormatException or OverflowException or IOException)
        { throw Invalid(); }
    }
    private static IOException Invalid() => new("This pairing code is invalid. Copy a new code from Pair a device on the other computer.");
}

/// Outgoing device identity is independent of this computer's hosting keys.
public sealed record ClientCredentials(byte[] Certificate, byte[] PrivateKey)
{
    public static ClientCredentials Create()
    {
        using var rsa = RSA.Create(2048);
        var request = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=Nocturne Windows", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(20));
        return new(certificate.Export(X509ContentType.Cert), rsa.ExportPkcs8PrivateKey());
    }
    public byte[] Sign(byte[] challenge)
    {
        using var rsa = RSA.Create(); rsa.ImportPkcs8PrivateKey(PrivateKey, out var read);
        if (read != PrivateKey.Length) throw new IOException("The saved client identity is invalid.");
        var signature = rsa.SignData(Encoding.UTF8.GetBytes("nocturne-workspace-device-v2\0").Concat(challenge).ToArray(),
            HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        _ = Wire.VerifyIdentity(Certificate, signature, challenge); return signature;
    }
}

public interface IClientTunnel : IDisposable { ushort Port { get; } string Route { get; } }

public sealed class WorkspaceClient : IAsyncDisposable
{
    private readonly TcpClient socket;
    private readonly Stream stream;
    private readonly IClientTunnel? tunnel;
    private readonly ConcurrentDictionary<string, TaskCompletionSource<Packet>> requests = [];
    private readonly SemaphoreSlim writes = new(1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task reader;
    private int disposed;
    public ClientInvitation Invitation { get; }
    public string[] Capabilities { get; }
    public string Route => tunnel?.Route ?? "Local network";
    public event Action<Packet>? Media;
    public event Action<Exception>? Disconnected;
    private WorkspaceClient(TcpClient socket, Stream stream, IClientTunnel? tunnel, ClientInvitation invitation, Packet authenticated)
    {
        this.socket = socket; this.stream = stream; this.tunnel = tunnel;
        Invitation = invitation with { Name = authenticated.Name ?? invitation.Name, EnrollmentToken = null };
        Capabilities = authenticated.Capabilities ?? [];
        reader = Task.Factory.StartNew(ReadLoop, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }
    public static async Task<WorkspaceClient> ConnectAsync(ClientInvitation invitation, ClientCredentials identity, string deviceName,
        CancellationToken cancellation = default, Func<RemoteAccessInfo, CancellationToken, Task<IClientTunnel>>? makeTunnel = null)
    {
        makeTunnel ??= RemoteClient.ConnectAsync;
        if (invitation.Secret?.Length != 32 || invitation.Port == 0 || string.IsNullOrWhiteSpace(invitation.Host)) throw new IOException("The saved pairing is invalid. Pair this host again.");
        try { return await ConnectTo(invitation.Host, invitation.Port, null); }
        catch (Exception error) when (!cancellation.IsCancellationRequested && error is IOException or SocketException or OperationCanceledException)
        {
            var candidate = await WorkspaceDiscovery.FindAsync(invitation.Secret, cancellation);
            if (candidate is { } address && (address.Host != invitation.Host || address.Port != invitation.Port))
            {
                try { return await ConnectTo(address.Host, address.Port, null); }
                catch (Exception retry) when (!cancellation.IsCancellationRequested && retry is IOException or SocketException or OperationCanceledException) { }
            }
            if (invitation.RemoteAccess == null) throw;
            var tunnel = await makeTunnel(invitation.RemoteAccess, cancellation);
            try { return await ConnectTo("127.0.0.1", tunnel.Port, tunnel); }
            catch { tunnel.Dispose(); throw; }
        }
        async Task<WorkspaceClient> ConnectTo(string host, ushort port, IClientTunnel? remote)
        {
            var socket = new TcpClient { NoDelay = true, ReceiveTimeout = 12_000, SendTimeout = 12_000 };
            try
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                deadline.CancelAfter(TimeSpan.FromSeconds(remote == null ? 4 : 15));
                await socket.ConnectAsync(host, port, deadline.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(12));
                return await Task.Factory.StartNew(() =>
                {
                    using var abort = deadline.Token.Register(socket.Dispose);
                    var protocol = new TlsClientProtocol(socket.GetStream());
                    var tls = new ClientTls(invitation.Secret); protocol.Connect(tls);
                    var hello = new Packet("hello") { Version = Wire.Version };
                    protocol.Stream.Write(Wire.Encode(hello)); var challenge = Wire.Read(protocol.Stream);
                    CheckReply(hello, challenge);
                    if (challenge.Version != Wire.Version || challenge.Data?.Length != 32) throw new IOException("Update both Nocturne apps to the same version.");
                    var auth = new Packet("authenticate") { Name = deviceName, Certificate = identity.Certificate,
                        Signature = identity.Sign(tls.BoundChallenge(challenge.Data)), EnrollmentToken = invitation.EnrollmentToken };
                    protocol.Stream.Write(Wire.Encode(auth)); var reply = Wire.Read(protocol.Stream); CheckReply(auth, reply);
                    if (reply.Version != Wire.Version) throw new IOException("Update both Nocturne apps to the same version.");
                    deadline.Token.ThrowIfCancellationRequested(); socket.ReceiveTimeout = 0;
                    return new WorkspaceClient(socket, protocol.Stream, remote, remote == null ? invitation with { Host = host, Port = port } : invitation, reply);
                }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            }
            catch { socket.Dispose(); throw; }
        }
    }
    public async Task<Packet> RequestAsync(Packet packet, CancellationToken cancellation = default, int timeoutSeconds = 12)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        if (requests.Count >= 128) throw new IOException("The connection is too slow. Reconnect to continue.");
        var completion = new TaskCompletionSource<Packet>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!requests.TryAdd(packet.Id, completion)) throw new IOException("Duplicate request.");
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellation);
            deadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
            await writes.WaitAsync(deadline.Token);
            try { await stream.WriteAsync(Wire.Encode(packet), deadline.Token); }
            finally { writes.Release(); }
            var reply = await completion.Task.WaitAsync(deadline.Token); CheckReply(packet, reply); return reply;
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new IOException("The host did not respond. Reconnect to continue."); }
        finally { requests.TryRemove(packet.Id, out _); }
    }
    private void ReadLoop()
    {
        Exception error = new IOException("The host disconnected.");
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var packet = Wire.Read(stream);
                if (packet.Operation is "appVideo" or "appEnded" or "desktopVideo" or "desktopAudio" or "desktopEnded") Media?.Invoke(packet);
                else if (requests.TryRemove(packet.Id, out var pending)) pending.TrySetResult(packet);
            }
        }
        catch (Exception failure) { error = failure; }
        finally
        {
            lifetime.Cancel(); socket.Dispose();
            foreach (var pending in requests.Values) pending.TrySetException(error);
            if (Volatile.Read(ref disposed) == 0) Disconnected?.Invoke(error);
        }
    }
    private static void CheckReply(Packet request, Packet reply)
    {
        if (reply.Id != request.Id || reply.Operation != request.Operation) throw new IOException("The host sent an invalid reply.");
        if (reply.Error != null) throw new IOException(reply.Error);
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel(); socket.Dispose();
        try { await reader; } finally { tunnel?.Dispose(); lifetime.Dispose(); }
    }
    private sealed class ClientTls(byte[] secret) : PskTlsClient(new BcTlsCrypto(new SecureRandom()),
        new BasicTlsPskIdentity("nocturne-v1", secret))
    {
        private byte[]? binding;
        protected override int[] GetSupportedCipherSuites() => [CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256];
        protected override ProtocolVersion[] GetSupportedVersions() => [ProtocolVersion.TLSv12];
        public override void NotifyHandshakeComplete() { base.NotifyHandshakeComplete(); binding = m_context.ExportKeyingMaterial(Wire.ExporterLabel, [], 32); }
        public byte[] BoundChallenge(byte[] nonce) => SHA256.HashData(nonce.Concat(binding ?? throw new IOException("TLS is not ready.")).ToArray());
    }
}

/// Strict fragmentation prevents untrusted hosts allocating arbitrary video buffers.
public sealed class VideoAssembler
{
    private string? id;
    private long total;
    private AppVideo? first;
    private MemoryStream bytes = new();
    public AppVideo? Receive(Packet packet)
    {
        var video = packet.Video;
        if (video?.Data is not { Length: > 0 and <= 4194304 } || !double.IsFinite(video.Timestamp) ||
            video.ParameterSets?.Length != 2 || video.ParameterSets.Any(set => set is not { Length: > 0 and <= 4096 })) throw Invalid();
        if (packet.TransferID == null && packet.Offset == null && packet.Size == null) { Reset(); return video; }
        if (packet.TransferID is not { Length: > 0 and <= 64 } || packet.Offset is not >= 0 || packet.Size is not (> 0 and <= 4194304) ||
            video.Data.Length > Wire.ChunkSize || packet.Offset > packet.Size || video.Data.Length > packet.Size - packet.Offset) throw Invalid();
        if (packet.Offset == 0) { Reset(); id = packet.TransferID; total = packet.Size.Value; first = video; }
        if (id != packet.TransferID || total != packet.Size || bytes.Length != packet.Offset || first?.Timestamp != video.Timestamp ||
            !first.ParameterSets.Zip(video.ParameterSets).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second))) throw Invalid();
        bytes.Write(video.Data);
        if (bytes.Length != total) return null;
        var result = first with { Data = bytes.ToArray() }; Reset(); return result;
    }
    public void Reset() { id = null; first = null; total = 0; bytes.Dispose(); bytes = new(); }
    private static IOException Invalid() => new("The host sent an invalid video frame.");
    public static byte[] AnnexB(AppVideo video)
    {
        using var output = new MemoryStream();
        foreach (var set in video.ParameterSets) { output.Write([0, 0, 0, 1]); output.Write(set); }
        for (var offset = 0; offset < video.Data.Length;)
        {
            if (video.Data.Length - offset < 4) throw Invalid();
            var count = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(video.Data.AsSpan(offset)); offset += 4;
            if (count <= 0 || count > video.Data.Length - offset) throw Invalid();
            output.Write([0, 0, 0, 1]); output.Write(video.Data, offset, count); offset += count;
        }
        return output.ToArray();
    }
}
