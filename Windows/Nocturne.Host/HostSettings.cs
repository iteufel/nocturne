using System.Text;

namespace Nocturne.Host;

public sealed record HostSettings
{
    public string Name { get; init; } = Environment.MachineName;
    public string SharedFolder { get; init; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Nocturne Shared");
    public bool ScreenSharing { get; init; } = true;
    public bool Terminal { get; init; }
    public bool Files { get; init; }
    public bool Microphone { get; init; }
    public string MicrophoneDevice { get; init; } = "";
    public bool LaunchAtLogin { get; init; }
    public bool RemoteAccess { get; init; }
    public string BrokerURL { get; init; } = "https://nocturne.alkal.de";
    public string PhysicalDisplay { get; init; } = "";
    public bool HeadlessDisplay { get; init; }
    public bool DisablePhysicalDisplays { get; init; }
    public bool HasEnabledServices => ScreenSharing || Terminal || Files || Microphone;

    public HostSettings Validated()
    {
        var name = Name.Trim();
        if (name.Length == 0 || name.Any(char.IsControl) || Encoding.UTF8.GetByteCount(name) > 128)
            throw new IOException("Enter a computer name without control characters.");
        if (DisablePhysicalDisplays && !HeadlessDisplay)
            throw new IOException("Enable Headless virtual monitor before turning off physical displays.");
        if (Files && (string.IsNullOrWhiteSpace(SharedFolder) || !Path.IsPathFullyQualified(SharedFolder)))
            throw new IOException("Choose an absolute folder path to share.");
        if (Microphone && string.IsNullOrWhiteSpace(MicrophoneDevice))
            throw new IOException("Choose your virtual microphone's playback endpoint in Sharing.");
        var broker = BrokerURL.Trim();
        if (RemoteAccess) broker = RemoteAccessInfo.ValidateBroker(broker);
        return this with { Name = name, BrokerURL = broker };
    }
}

public sealed record RemoteAccessInfo(string BrokerURL, string EndpointID)
{
    public static string ValidateBroker(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host) ||
            !(uri.Scheme == "https" || uri.Scheme == "http" && uri.IsLoopback) ||
            uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
            uri.AbsolutePath != "/" || uri.Port is < 1 or > 65535)
            throw new IOException("Enter the broker's HTTPS address, such as https://broker.example.com.");
        return uri.GetLeftPart(UriPartial.Authority).TrimEnd('/');
    }
}
