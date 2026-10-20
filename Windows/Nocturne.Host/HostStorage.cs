using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

namespace Nocturne.Host;

[SupportedOSPlatform("windows")]
public sealed class HostStorage
{
    public string DirectoryPath { get; }
    public HostStorage(string? directory = null)
    {
        DirectoryPath = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nocturne");
        Directory.CreateDirectory(DirectoryPath);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        var user = WindowsIdentity.GetCurrent().User ?? throw new IOException("A signed-in Windows user is required.");
        foreach (var identity in new[] { user, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                     new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
            security.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(DirectoryPath).SetAccessControl(security);
    }
    public HostSettings LoadSettings() => File.Exists(Path.Combine(DirectoryPath, "settings.json"))
        ? JsonSerializer.Deserialize<HostSettings>(File.ReadAllBytes(Path.Combine(DirectoryPath, "settings.json")), Wire.Json)
            ?? throw new IOException("Settings could not be read.") : new();
    public void SaveSettings(HostSettings settings) => AtomicWrite("settings.json", JsonSerializer.SerializeToUtf8Bytes(settings, Wire.Json));
    public byte[] LoadSecret() => LoadKey("workspace.key");
    public byte[] LoadEndpointKey() => LoadKey("remote.key");
    private byte[] LoadKey(string name)
    {
        var file = Path.Combine(DirectoryPath, name);
        if (File.Exists(file))
        {
            var secret = ProtectedData.Unprotect(File.ReadAllBytes(file), null, DataProtectionScope.CurrentUser);
            if (secret.Length != 32) throw new IOException("The workspace key is invalid. Restore your Nocturne data before starting.");
            return secret;
        }
        var key = RandomNumberGenerator.GetBytes(32);
        AtomicWrite(name, ProtectedData.Protect(key, null, DataProtectionScope.CurrentUser));
        return key;
    }
    private void AtomicWrite(string name, byte[] data)
    {
        var temporary = Path.Combine(DirectoryPath, name + ".tmp");
        File.WriteAllBytes(temporary, data); File.Move(temporary, Path.Combine(DirectoryPath, name), true);
    }

    public static string[] NetworkAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses)
        .Select(a => a.Address).Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a) && a.GetAddressBytes()[0] != 169)
        .Select(a => a.ToString()).Distinct().ToArray();
}
