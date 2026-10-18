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
    private readonly HostStorage storage = new();
    private readonly DeviceStore devices;
    private readonly byte[] secret;
    private WorkspaceServer? workspace;
    private StreamingEngine? engine;
    private CancellationTokenSource? lifetime;
    private bool running, busy;
    private string? error;
    private string? startupFailure;
    private string name;
    public string Name { get => name; set { name = value; Changed(); } }
    public string SharedFolder { get; set; }
    public bool Terminal { get; set; }
    public bool Files { get; set; }
    public bool Running => running;
    public bool CanAct => !busy;
    public bool CanPair => running && !busy;
    public bool CanConfigure => !running && !busy;
    public bool NoDevices => Devices.Count == 0;
    public string StartLabel => busy ? "Please wait…" : running ? "Stop server" : "Start server";
    public string Status => busy ? "Updating server…" : running ? "Ready to connect" : "Server stopped";
    public string? Error => error;
    public bool HasError => !string.IsNullOrEmpty(error);
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    public string LogPath => Path.Combine(storage.DirectoryPath, "Engine", "engine.log");
    public bool HasInvitation => devices.HasInvitation;
    public event PropertyChangedEventHandler? PropertyChanged;
    private readonly System.Windows.Threading.DispatcherTimer refresh;

    public ServerModel()
    {
        var settings = storage.LoadSettings(); name = settings.Name; SharedFolder = settings.SharedFolder;
        Terminal = settings.Terminal; Files = settings.Files;
        secret = storage.LoadSecret();
        devices = new(Path.Combine(storage.DirectoryPath, "devices.json"));
        refresh = new() { Interval = TimeSpan.FromSeconds(2) };
        refresh.Tick += (_, _) => RefreshDevices(); refresh.Start();
        RefreshDevices();
    }

    public async Task RunAsync(Func<Task> action)
    {
        if (busy) return;
        busy = true; error = null; NotifyState();
        try { await action(); }
        catch (Exception ex) { error = ex.Message; }
        finally
        {
            if (startupFailure != null)
            {
                var message = startupFailure; startupFailure = null;
                try { await StopAsync(); } catch (Exception ex) { message += " " + ex.Message; }
                error = message;
            }
            busy = false; NotifyState(); RefreshDevices();
        }
    }

    public void SaveSettings()
    {
        if (running) throw new IOException("Stop the server before changing settings.");
        Name = Name.Trim();
        if (Name.Length == 0 || Name.Any(char.IsControl) || System.Text.Encoding.UTF8.GetByteCount(Name) > 128)
            throw new IOException("Enter a computer name without control characters.");
        storage.SaveSettings(new() { Name = Name, SharedFolder = SharedFolder, Terminal = Terminal, Files = Files });
    }

    public async Task StartAsync()
    {
        SaveSettings(); lifetime = new();
        var nextEngine = new StreamingEngine(Path.Combine(storage.DirectoryPath, "Engine")); engine = nextEngine;
        nextEngine.UnexpectedExit += message => Application.Current.Dispatcher.BeginInvoke(async () =>
        {
            if (!ReferenceEquals(engine, nextEngine)) return;
            lifetime?.Cancel();
            if (!running) { startupFailure = message; return; }
            if (busy)
            {
                startupFailure = message;
                try { await StopAsync(); } catch (Exception ex) { startupFailure += " " + ex.Message; }
            }
            else await RunAsync(async () => { await StopAsync(); throw new IOException(message); });
        });
        IWorkspaceFiles? folder = null;
        try
        {
            if (Files) folder = new WindowsSharedFolder(SharedFolder);
            await nextEngine.StartAsync(Path.Combine(AppContext.BaseDirectory, "engine", "sunshine.exe"), Name, lifetime.Token);
            lifetime.Token.ThrowIfCancellationRequested();
            workspace = new(Name, secret, devices, new(Terminal, Files), folder, (columns, rows) => new ConPtyTerminal(columns, rows), nextEngine);
            folder = null; workspace.Start(); running = true;
            foreach (var (id, pendingName) in devices.PendingRemovals)
                await workspace.RemoveDeviceAsync(id, pendingName, lifetime.Token);
        }
        catch { folder?.Dispose(); await StopAsync(); throw; }
    }

    public async Task StopAsync()
    {
        lifetime?.Cancel(); devices.CancelInvitation();
        running = false;
        var oldWorkspace = workspace; workspace = null;
        var oldEngine = engine; engine = null;
        try { if (oldWorkspace != null) await oldWorkspace.DisposeAsync(); }
        finally
        {
            if (oldEngine != null) await oldEngine.DisposeAsync();
            lifetime?.Dispose(); lifetime = null; NotifyState();
        }
    }

    public string CreateInvitation(string address)
    {
        if (!running) throw new IOException("Start the server before pairing.");
        return Wire.Invitation(address, Name, secret, devices.CreateInvitation());
    }
    public void CancelInvitation() => devices.CancelInvitation();
    public Task RemoveAsync(DeviceRow device) => (workspace ?? throw new IOException("Start the server to remove this device."))
        .RemoveDeviceAsync(device.Id, device.Name, lifetime!.Token);

    private void RefreshDevices()
    {
        try
        {
            var connected = workspace?.ConnectedDevices ?? [];
            var pending = devices.PendingRemovals;
            var savedEngine = engine ?? new StreamingEngine(Path.Combine(storage.DirectoryPath, "Engine"));
            var roster = devices.Devices.Concat(savedEngine.SavedDevices())
                .Concat(pending.Select(kv => new Device(kv.Key, kv.Value, DateTimeOffset.MinValue)))
                .GroupBy(d => d.Id).Select(g => g.First()).OrderBy(d => d.Name);
            Devices.Clear();
            foreach (var device in roster) Devices.Add(new(device.Id, device.Name,
                pending.ContainsKey(device.Id) ? "Removal pending · retry removal" : connected.Contains(device.Id) ? "Connected" : "Paired"));
            Changed(nameof(NoDevices));
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or CryptographicException)
        { error = "The device list could not be refreshed: " + ex.Message; Changed(nameof(Error)); Changed(nameof(HasError)); }
    }

    public async Task CloseAsync()
    {
        refresh.Stop(); await StopAsync(); CryptographicOperations.ZeroMemory(secret);
    }
    private void NotifyState()
    {
        foreach (var property in new[] { nameof(Running), nameof(CanAct), nameof(CanPair), nameof(CanConfigure), nameof(StartLabel), nameof(Status), nameof(Error), nameof(HasError) }) Changed(property);
    }
    private void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
}
