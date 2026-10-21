using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using Nocturne.Host;

namespace Nocturne.Server;

public sealed record ComputerRow(string Id, string Name, string Address);

internal sealed class ComputerModel : INotifyPropertyChanged
{
    private readonly HostStorage storage;
    private readonly Dictionary<string, ClientInvitation> hosts;
    private ClientCredentials? identity;
    private readonly Dictionary<string, RemoteStreamWindow> windows = [];
    private RemoteAppsWindow? browser;
    public ObservableCollection<ComputerRow> Computers { get; } = [];
    public bool NoComputers => Computers.Count == 0;
    public event PropertyChangedEventHandler? PropertyChanged;
    public ComputerModel(HostStorage storage)
    {
        this.storage = storage;
        var saved = storage.ReadClientData("client-hosts");
        hosts = saved == null ? [] : JsonSerializer.Deserialize<Dictionary<string, ClientInvitation>>(saved, Wire.Json)
            ?? throw new IOException("Saved hosts could not be read.");
        Refresh();
    }
    private ClientCredentials Identity()
    {
        if (identity != null) return identity;
        var saved = storage.ReadClientData("client-identity");
        var created = saved == null ? ClientCredentials.Create() : JsonSerializer.Deserialize<ClientCredentials>(saved, Wire.Json)
            ?? throw new IOException("The client identity could not be read.");
        _ = created.Sign(RandomNumberGenerator.GetBytes(32));
        if (saved == null) storage.WriteClientData("client-identity", JsonSerializer.SerializeToUtf8Bytes(created, Wire.Json));
        return identity = created;
    }
    public void Add(string code)
    {
        var invitation = ClientInvitation.Parse(code);
        var local = storage.LoadSecret();
        try { if (CryptographicOperations.FixedTimeEquals(local, invitation.Secret)) throw new IOException("Copy a pairing code from the other computer. This code belongs to this PC."); }
        finally { CryptographicOperations.ZeroMemory(local); }
        Open(invitation);
    }
    public void Connect(string id) { if (hosts.TryGetValue(id, out var invitation)) Open(invitation); }
    private void Open(ClientInvitation invitation, RemoteAppWindow? app = null)
    {
        var id = app == null ? "desktop" : invitation.Id + ":" + app.Id;
        if (windows.TryGetValue(id, out var existing)) { existing.Show(); existing.Activate(); return; }
        if (app != null && windows.Count(pair => pair.Key.StartsWith(invitation.Id + ":", StringComparison.Ordinal)) >= 4)
            throw new IOException("Close an app stream before opening another window.");
        var window = new RemoteStreamWindow(invitation, Identity(), Save, app, () => Browse(invitation.Id));
        windows[id] = window; window.Closed += (_, _) => windows.Remove(id);
        window.Show();
    }
    public void Browse(string id)
    {
        if (!hosts.TryGetValue(id, out var invitation)) return;
        if (browser != null) { browser.Close(); browser = null; }
        var next = new RemoteAppsWindow(invitation, Identity(), Save, app => Open(invitation, app));
        browser = next; next.Closed += (_, _) => { if (browser == next) browser = null; }; next.Show();
    }
    private void Save(ClientInvitation invitation)
    {
        var next = new Dictionary<string, ClientInvitation>(hosts) { [invitation.Id] = invitation with { EnrollmentToken = null } };
        storage.WriteClientData("client-hosts", JsonSerializer.SerializeToUtf8Bytes(next, Wire.Json));
        hosts.Clear(); foreach (var pair in next) hosts.Add(pair.Key, pair.Value); Refresh();
    }
    public void Forget(string id)
    {
        if (windows.Values.Any(window => window.ServerId == id) || browser?.ServerId == id)
            throw new IOException("Close this computer’s desktop and app windows before forgetting it.");
        var next = new Dictionary<string, ClientInvitation>(hosts); next.Remove(id);
        storage.WriteClientData("client-hosts", JsonSerializer.SerializeToUtf8Bytes(next, Wire.Json)); hosts.Remove(id); Refresh();
    }
    private void Refresh()
    {
        Computers.Clear(); foreach (var host in hosts.Values.OrderBy(host => host.Name)) Computers.Add(new(host.Id, host.Name, host.Host));
        PropertyChanged?.Invoke(this, new(nameof(NoComputers)));
    }
    public void Close()
    {
        browser?.Close(); foreach (var window in windows.Values.ToArray()) window.Close();
        if (identity != null) CryptographicOperations.ZeroMemory(identity.PrivateKey);
    }
}
