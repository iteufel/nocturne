using System.IO;
using System.Security.Cryptography;
using Nocturne.Host;

namespace Nocturne.Server;

/// The workspace remains available while capture or the remote broker recovers.
internal sealed class WindowsHostRuntime : IRunningHost
{
    private readonly HostSettings settings;
    private readonly StreamingEngine engine;
    private readonly WorkspaceServer workspace;
    private readonly CancellationTokenSource lifetime = new();
    private readonly RemoteSession remote = new();
    private readonly Action<string> changed;
    private readonly HostStorage storage;
    private Task? captureTask, remoteTask;
    private WorkspaceDiscovery.Advertisement? discovery;
    private volatile string screenStatus = "Disabled", remoteStatus = "Local network";
    public string[] ConnectedDevices => workspace.ConnectedDevices;
    public RemoteAccessInfo? RemoteAccess => remote.Access;
    public string ScreenSharingStatus => screenStatus;
    public string RemoteStatus => remoteStatus;
    private WindowsHostRuntime(HostStorage storage, HostSettings settings, byte[] secret, DeviceStore devices, Action<string> changed)
    {
        this.storage = storage; this.settings = settings; this.changed = changed;
        engine = new(Path.Combine(storage.DirectoryPath, "Engine"));
        IWorkspaceFiles? folder = null;
        MicrophoneSession? microphone = null; DisplaySession? display = null; AppWindowSessions? apps = null; DesktopSessions? desktop = null;
        try
        {
            if (settings.Files) folder = new WindowsSharedFolder(settings.SharedFolder);
            if (settings.Microphone) microphone = new(new ThreadBoundMicrophoneOutput(() => new WindowsMicrophoneOutput(settings.MicrophoneDevice)));
            if (settings.ScreenSharing) { display = new(new WindowsDisplayControl(settings, storage.DirectoryPath, lifetime.Token)); apps = new(new WindowsApplications()); desktop = new(new WindowsDesktopHost()); }
            workspace = new(settings.Name, secret, devices, new(settings.Terminal, settings.Files, settings.Microphone, settings.ScreenSharing), folder,
                (columns, rows) => new ConPtyTerminal(columns, rows), engine, microphone, display, apps, remote, desktop);
        }
        catch { folder?.Dispose(); microphone?.Dispose(); display?.Dispose(); apps?.Dispose(); desktop?.Dispose(); throw; }
        workspace.SessionError += message => changed(message);
    }
    public static async Task<IRunningHost> StartAsync(HostStorage storage, HostSettings settings, byte[] secret, DeviceStore devices, Action<string> changed, CancellationToken cancellation)
    {
        var runtime = new WindowsHostRuntime(storage, settings, secret, devices, changed);
        try
        {
            cancellation.ThrowIfCancellationRequested(); runtime.workspace.Start();
            try { runtime.discovery = new(secret, Wire.Port); }
            catch (System.Net.Sockets.SocketException error) { changed("Local discovery unavailable: " + error.Message); }
            foreach (var (id, name) in devices.PendingRemovals) await runtime.workspace.RemoveDeviceAsync(id, name, cancellation);
            if (settings.ScreenSharing) runtime.captureTask = Task.Run(runtime.MaintainCaptureAsync);
            if (settings.RemoteAccess) runtime.remoteTask = Task.Run(runtime.MaintainRemoteAsync);
            changed("Enabled host services started."); return runtime;
        }
        catch { await runtime.DisposeAsync(); throw; }
    }
    private async Task MaintainCaptureAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            var exited = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            void OnExit(string error) => exited.TrySetResult(error);
            engine.UnexpectedExit += OnExit;
            try
            {
                screenStatus = "Starting…"; changed("Starting screen sharing.");
                await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "engine", "sunshine.exe"), settings.Name, lifetime.Token);
                screenStatus = "Ready"; changed("Screen sharing ready.");
                var error = await exited.Task.WaitAsync(lifetime.Token);
                throw new IOException(error);
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
            catch (Exception error)
            {
                screenStatus = "Retrying · " + error.Message; changed(screenStatus);
                await engine.DisposeAsync();
                try { await Task.Delay(TimeSpan.FromSeconds(5), lifetime.Token); } catch (OperationCanceledException) { break; }
            }
            finally { engine.UnexpectedExit -= OnExit; }
        }
    }
    private async Task MaintainRemoteAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            byte[]? key = null;
            try
            {
                remoteStatus = "Connecting to broker…"; changed(remoteStatus);
                key = storage.LoadEndpointKey();
                var host = await RemoteHost.StartAsync(settings.BrokerURL, key, Wire.Port, lifetime.Token);
                remote.Attach(host, new(settings.BrokerURL, host.EndpointID));
                remoteStatus = "Ready · peer to peer with encrypted relay fallback"; changed(remoteStatus);
                await Task.Delay(Timeout.InfiniteTimeSpan, lifetime.Token);
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
            catch (Exception error)
            {
                remoteStatus = "Retrying · " + error.Message; changed(remoteStatus);
                try { await Task.Delay(TimeSpan.FromSeconds(5), lifetime.Token); } catch (OperationCanceledException) { break; }
            }
            finally { if (key != null) CryptographicOperations.ZeroMemory(key); }
        }
    }
    public Task RemoveDeviceAsync(string id, string name, CancellationToken cancellation) => workspace.RemoveDeviceAsync(id, name, cancellation);
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        discovery?.Dispose();
        try { await workspace.DisposeAsync(); }
        finally
        {
            try { await Task.WhenAll(new[] { captureTask, remoteTask }.OfType<Task>()); }
            finally { remote.Dispose(); await engine.DisposeAsync(); lifetime.Dispose(); }
        }
    }
    private sealed class RemoteSession : IRemoteHost
    {
        private readonly object gate = new();
        private RemoteHost? host;
        private RemoteAccessInfo? access;
        private bool disposed;
        public RemoteAccessInfo? Access { get { lock (gate) return access; } }
        public string EndpointID { get { lock (gate) return access?.EndpointID ?? ""; } }
        public void Attach(RemoteHost value, RemoteAccessInfo info)
        {
            lock (gate) { if (disposed) { value.Dispose(); return; } host = value; access = info; }
        }
        public void Authorize(ushort port, string device) { lock (gate) host?.Authorize(port, device); }
        public void Revoke(string device) { lock (gate) host?.Revoke(device); }
        public void Dispose() { lock (gate) { disposed = true; host?.Dispose(); host = null; access = null; } }
    }
}
