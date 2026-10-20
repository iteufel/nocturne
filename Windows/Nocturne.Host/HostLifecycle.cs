namespace Nocturne.Host;

public interface ILoginStartup
{
    bool Enabled { get; }
    void SetEnabled(bool enabled);
}

public interface IRunningHost : IAsyncDisposable
{
    string[] ConnectedDevices { get; }
    RemoteAccessInfo? RemoteAccess { get; }
    string ScreenSharingStatus { get; }
    Task RemoveDeviceAsync(string id, string name, CancellationToken cancellation);
}

/// Draft settings only become active after validation, persistence, and login registration succeed.
public sealed class HostLifecycle(HostSettings saved, ILoginStartup login, Action<HostSettings> save,
    Func<HostSettings, CancellationToken, Task<IRunningHost>> start) : IAsyncDisposable
{
    private readonly SemaphoreSlim gate = new(1);
    private readonly CancellationTokenSource lifetime = new();
    public HostSettings Settings { get; private set; } = saved with { LaunchAtLogin = login.Enabled };
    public IRunningHost? Runtime { get; private set; }
    public bool Running => Runtime != null;
    public async Task StartAsync()
    {
        await gate.WaitAsync(lifetime.Token);
        try { if (Runtime == null && Settings.HasEnabledServices) Runtime = await start(Settings.Validated(), lifetime.Token); }
        finally { gate.Release(); }
    }
    public async Task ApplyAsync(HostSettings draft)
    {
        var next = draft.Validated();
        await gate.WaitAsync(lifetime.Token);
        try
        {
            if (next == Settings) return;
            var previousLogin = login.Enabled;
            if (previousLogin != next.LaunchAtLogin) login.SetEnabled(next.LaunchAtLogin);
            try { save(next); }
            catch { if (previousLogin != next.LaunchAtLogin) login.SetEnabled(previousLogin); throw; }
            Settings = next;
            var previous = Runtime; Runtime = null;
            if (previous != null) await previous.DisposeAsync();
            if (next.HasEnabledServices) Runtime = await start(next, lifetime.Token);
        }
        finally { gate.Release(); }
    }
    public void RefreshLogin() => Settings = Settings with { LaunchAtLogin = login.Enabled };
    public async Task StopAsync()
    {
        await gate.WaitAsync();
        try { var previous = Runtime; Runtime = null; if (previous != null) await previous.DisposeAsync(); }
        finally { gate.Release(); }
    }
    public async ValueTask DisposeAsync() { lifetime.Cancel(); await StopAsync(); lifetime.Dispose(); }
}
