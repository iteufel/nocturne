using System.Net;
using System.Text.Json;
using Nocturne.Host;

// Test-only listener: exercises the actual Windows protocol implementation from Swift.
// Ephemeral test secrets are exchanged through inherited pipes, never command-line arguments.
var root = Path.Combine(Path.GetTempPath(), "nocturne-interop-" + Guid.NewGuid());
try
{
    var secret = Convert.FromBase64String(Console.ReadLine() ?? throw new IOException("Missing test key."));
    var devices = new DeviceStore(Path.Combine(root, "devices.json"));
    var media = args.Contains("--media");
    await using var server = new WorkspaceServer("Windows interop host", secret, devices, new(Microphone: media), null,
        (_, _) => throw new IOException("Terminal is disabled in the interoperability fixture."),
        microphone: media ? new(new FixtureMicrophone()) : null,
        display: media ? new(new FixtureDisplay()) : null, applications: media ? new(new FixtureApps()) : null);
    server.SessionError += message => Console.Error.WriteLine(message);
    server.Start(0, IPAddress.Loopback);
    Console.WriteLine(JsonSerializer.Serialize(new { port = server.Port, token = devices.CreateInvitation() }, Wire.Json));
    while (Console.ReadLine() != null) { }
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }

sealed class FixtureMicrophone : IMicrophoneOutput
{
    public void Start() { }
    public void Write(byte[] pcm) { }
    public void Stop() { }
    public void Dispose() { }
}
sealed class FixtureDisplay : IDisplayControl
{
    public DisplaySize Prepare(DisplaySize size) => size;
    public void Restore() { }
    public void Dispose() { }
}
sealed class FixtureApps : IAppWindowHost
{
    public RemoteApplication[] Applications() => [new("fixture-app", "Fixture App")];
    public RemoteAppWindow[] Windows(string? application) => [new(1, "fixture-app", "Fixture Window", 640, 480)];
    public byte[] Icon(string application) => [];
    public RemoteAppWindow[] Launch(string application) => Windows(application);
    public IAppWindowCapture Capture(string application, uint window, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended) => new FixtureCapture(viewport);
    public void Dispose() { }
}
sealed class FixtureCapture(AppViewport viewport) : IAppWindowCapture
{
    private AppViewport viewport = viewport;
    public RemoteAppWindow Window => new(1, "fixture-app", "Fixture Window", viewport.Width, viewport.Height);
    public DisplaySize Display => viewport.Pixels();
    public void Resize(AppViewport value) => viewport = value;
    public void Input(AppInput input) { }
    public void Dispose() { }
}
