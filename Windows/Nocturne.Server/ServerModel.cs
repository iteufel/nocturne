using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Windows;
using Nocturne.Host;

namespace Nocturne.Server;

public sealed record DeviceRow(string Id, string Name, string Status);

public sealed class ServerModel : INotifyPropertyChanged
{
    private readonly HostStorage storage;
    private readonly DeviceStore devices;
    private readonly byte[] secret;
    private readonly HostLifecycle lifecycle;
    private readonly System.Windows.Threading.DispatcherTimer refresh;
    private HostSettings draft;
    private bool busy;
    private string? error;
    public string Name { get => draft.Name; set { draft = draft with { Name = value }; SettingsChanged(); } }
    public string SharedFolder { get => draft.SharedFolder; set { draft = draft with { SharedFolder = value }; SettingsChanged(); } }
    public bool ScreenSharing { get => draft.ScreenSharing; set { draft = draft with { ScreenSharing = value }; SettingsChanged(); } }
    public bool Terminal { get => draft.Terminal; set { draft = draft with { Terminal = value }; SettingsChanged(); } }
    public bool Files { get => draft.Files; set { draft = draft with { Files = value }; SettingsChanged(); } }
    public bool Microphone { get => draft.Microphone; set { draft = draft with { Microphone = value }; SettingsChanged(); } }
    public string MicrophoneDevice { get => draft.MicrophoneDevice; set { if (value == null) return; draft = draft with { MicrophoneDevice = value }; SettingsChanged(); } }
    public bool LaunchAtLogin { get => draft.LaunchAtLogin; set { draft = draft with { LaunchAtLogin = value }; SettingsChanged(); } }
    public bool RemoteAccess { get => draft.RemoteAccess; set { draft = draft with { RemoteAccess = value }; SettingsChanged(); } }
    public string BrokerURL { get => draft.BrokerURL; set { draft = draft with { BrokerURL = value }; SettingsChanged(); } }
    public string PhysicalDisplay { get => draft.PhysicalDisplay; set { if (value == null) return; draft = draft with { PhysicalDisplay = value }; SettingsChanged(); } }
    public bool HeadlessDisplay { get => draft.HeadlessDisplay; set { draft = draft with { HeadlessDisplay = value }; SettingsChanged(); } }
    public bool DisablePhysicalDisplays { get => draft.DisablePhysicalDisplays; set { draft = draft with { DisablePhysicalDisplays = value }; SettingsChanged(); } }
    public bool Running => lifecycle.Running;
    public bool CanAct => !busy;
    public bool CanPair => Running && !busy;
    public bool CanConfigure => !busy;
    public bool CanApply => !busy && HasSettingsChanges;
    public bool HasSettingsChanges => draft != lifecycle.Settings;
    public bool NoDevices => Devices.Count == 0;
    public string StartLabel => busy ? "Please wait…" : Running ? "Stop server" : "Start server";
    public string Status => busy ? "Updating server…" : Running ? "Ready to connect" : "Server stopped";
    public string ScreenStatus => lifecycle.Runtime?.ScreenSharingStatus ?? "Stopped";
    public string RemoteStatus => (lifecycle.Runtime as WindowsHostRuntime)?.RemoteStatus ?? "Stopped";
    public string? Error => error;
    public bool HasError => !string.IsNullOrEmpty(error);
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    public ObservableCollection<DisplayOption> Displays { get; } = [];
    public ObservableCollection<AudioEndpoint> AudioEndpoints { get; } = [];
    public string LogPath => Path.Combine(storage.DirectoryPath, "nocturne.log");
    public string EngineLogPath => Path.Combine(storage.DirectoryPath, "Engine", "engine.log");
    public bool HasInvitation => devices.HasInvitation;
    public event PropertyChangedEventHandler? PropertyChanged;
    private readonly object logGate = new();

    public ServerModel() : this(new HostStorage()) { }
    internal ServerModel(HostStorage storage)
    {
        this.storage = storage;
        secret = storage.LoadSecret(); devices = new(Path.Combine(storage.DirectoryPath, "devices.json"));
        lifecycle = new(storage.LoadSettings(), new WindowsStartup(), storage.SaveSettings,
            (settings, cancellation) => WindowsHostRuntime.StartAsync(storage, settings, secret, devices, RuntimeChanged, cancellation));
        draft = lifecycle.Settings;
        refresh = new() { Interval = TimeSpan.FromSeconds(2) };
        refresh.Tick += (_, _) => { RefreshDevices(); NotifyState(); }; refresh.Start();
        RefreshDevices();
    }
    public async Task InitializeAsync()
    {
        await Task.Run(() => WindowsDisplayControl.Recover(storage.DirectoryPath));
        await RefreshHardwareAsync(); await lifecycle.StartAsync(); NotifyState();
    }
    public async Task RefreshHardwareAsync()
    {
        var found = await Task.Run(() =>
        {
            DisplayOption[] displays = []; AudioEndpoint[] audio = []; var failures = new List<string>();
            try { displays = WindowsMedia.Displays(); } catch (Exception ex) { failures.Add("Displays: " + ex.Message); }
            try { audio = WindowsMedia.AudioEndpoints(); } catch (Exception ex) { failures.Add("Audio: " + ex.Message); }
            return (displays, audio, failures);
        });
        Displays.Clear(); Displays.Add(new("", "Automatic display", false)); foreach (var display in found.displays) Displays.Add(display);
        AudioEndpoints.Clear(); foreach (var endpoint in found.audio) AudioEndpoints.Add(endpoint);
        if (found.failures.Count != 0) { error = string.Join(" ", found.failures); Log(error); }
        Changed(nameof(PhysicalDisplay)); Changed(nameof(MicrophoneDevice));
    }
    public async Task RunAsync(Func<Task> action)
    {
        if (busy) return;
        busy = true; error = null; NotifyState();
        try { await action(); }
        catch (Exception ex) { error = ex.Message; Log(ex.Message); }
        finally { busy = false; NotifyState(); RefreshDevices(); }
    }
    public async Task ApplySettingsAsync()
    {
        await lifecycle.ApplyAsync(draft); draft = lifecycle.Settings; NotifySettings();
    }
    public void DiscardSettings() { draft = lifecycle.Settings; NotifySettings(); }
    public void RefreshLogin()
    {
        var old = lifecycle.Settings.LaunchAtLogin; lifecycle.RefreshLogin();
        if (draft.LaunchAtLogin == old) { draft = draft with { LaunchAtLogin = lifecycle.Settings.LaunchAtLogin }; Changed(nameof(LaunchAtLogin)); }
        SettingsChanged();
    }
    public Task StartAsync() => lifecycle.StartAsync();
    public async Task StopAsync() { devices.CancelInvitation(); await lifecycle.StopAsync(); NotifyState(); }
    public async Task RecoverDisplaysAsync() { await StopAsync(); await Task.Run(() => WindowsDisplayControl.Recover(storage.DirectoryPath)); }
    public string CreateInvitation(string address)
    {
        if (!Running) throw new IOException("Start the server before pairing.");
        return Wire.Invitation(address, lifecycle.Settings.Name, secret, devices.CreateInvitation(), lifecycle.Runtime?.RemoteAccess);
    }
    public void CancelInvitation() => devices.CancelInvitation();
    public async Task RemoveAsync(DeviceRow device)
    {
        if (lifecycle.Runtime is { } runtime) { await runtime.RemoveDeviceAsync(device.Id, device.Name, CancellationToken.None); return; }
        devices.Block(device.Id, device.Name);
        await using var engine = new StreamingEngine(Path.Combine(storage.DirectoryPath, "Engine"));
        await engine.RemoveAsync(device.Id, CancellationToken.None); devices.FinishRemoval(device.Id);
    }
    private void RefreshDevices()
    {
        try
        {
            var connected = lifecycle.Runtime?.ConnectedDevices ?? [];
            var pending = devices.PendingRemovals;
            var savedEngine = new StreamingEngine(Path.Combine(storage.DirectoryPath, "Engine"));
            var roster = devices.Devices.Concat(savedEngine.SavedDevices())
                .Concat(pending.Select(kv => new Device(kv.Key, kv.Value, DateTimeOffset.MinValue)))
                .GroupBy(device => device.Id).Select(group => group.First()).OrderByDescending(device => connected.Contains(device.Id)).ThenBy(device => device.Name);
            Devices.Clear();
            foreach (var device in roster) Devices.Add(new(device.Id, device.Name,
                pending.ContainsKey(device.Id) ? "Removal pending · retry removal" : connected.Contains(device.Id) ? "Connected" : "Paired"));
            Changed(nameof(NoDevices));
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or CryptographicException)
        { error = "The device list could not be refreshed: " + ex.Message; Changed(nameof(Error)); Changed(nameof(HasError)); }
    }
    private void RuntimeChanged(string message)
    {
        Log(message);
        if (!Application.Current.Dispatcher.HasShutdownStarted)
            _ = Application.Current.Dispatcher.BeginInvoke(() => { NotifyState(); RefreshDevices(); });
    }
    private void Log(string message)
    {
        lock (logGate)
        {
            try
            {
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 1_048_576) File.Move(LogPath, LogPath + ".previous", true);
                File.AppendAllText(LogPath, DateTimeOffset.Now.ToString("O") + " " + message.Replace('\r', ' ').Replace('\n', ' ') + Environment.NewLine);
            }
            catch (IOException) { }
        }
    }
    public async Task CloseAsync()
    {
        refresh.Stop(); devices.CancelInvitation();
        try { await lifecycle.DisposeAsync(); } finally { CryptographicOperations.ZeroMemory(secret); }
    }
    private void SettingsChanged([CallerMemberName] string? name = null) { Changed(name); Changed(nameof(HasSettingsChanges)); Changed(nameof(CanApply)); }
    private void NotifySettings()
    {
        foreach (var property in new[] { nameof(Name), nameof(SharedFolder), nameof(ScreenSharing), nameof(Terminal), nameof(Files), nameof(Microphone), nameof(MicrophoneDevice), nameof(LaunchAtLogin), nameof(RemoteAccess), nameof(BrokerURL), nameof(PhysicalDisplay), nameof(HeadlessDisplay), nameof(DisablePhysicalDisplays) }) Changed(property);
        SettingsChanged(); NotifyState();
    }
    private void NotifyState()
    {
        foreach (var property in new[] { nameof(Running), nameof(CanAct), nameof(CanPair), nameof(CanConfigure), nameof(CanApply), nameof(HasSettingsChanges), nameof(StartLabel), nameof(Status), nameof(ScreenStatus), nameof(RemoteStatus), nameof(Error), nameof(HasError) }) Changed(property);
    }
    private void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
}
