using System.Net;
using System.Text.Json;
using Nocturne.Host;

if (args.Contains("--client"))
{
    var invitation = ClientInvitation.Parse(Console.ReadLine() ?? throw new IOException("Missing fixture invitation."));
    var credentials = ClientCredentials.Create();
    await using (var client = await WorkspaceClient.ConnectAsync(invitation, credentials, "Windows receiver fixture"))
    {
        var video = new TaskCompletionSource<AppVideo>(TaskCreationOptions.RunContinuationsAsynchronously);
        var audio = new TaskCompletionSource<DesktopAudio>(TaskCreationOptions.RunContinuationsAsynchronously);
        var assembler = new VideoAssembler();
        client.Media += packet =>
        {
            if (packet.Operation == "desktopAudio" && packet.Audio?.IsValid == true) audio.TrySetResult(packet.Audio);
            if (packet.Operation == "desktopVideo" && assembler.Receive(packet) is { } frame) video.TrySetResult(frame);
        };
        var list = await client.RequestAsync(new("desktopList"));
        if (list.Displays?.FirstOrDefault()?.Id != 7) throw new IOException("Invalid display fixture.");
        var id = Guid.NewGuid().ToString();
        var opened = await client.RequestAsync(new("desktopOpen") { SessionID = id, DisplayID = 7, Viewport = new(640, 480, 1) });
        if (opened.SessionID != id || opened.DisplayID != 7) throw new IOException("Invalid desktop fixture.");
        await client.RequestAsync(new("desktopResize") { SessionID = id, Viewport = new(800, 600, 1) });
        await client.RequestAsync(new("desktopInput") { SessionID = id, Input = new("text", Text: "Windows to Mac") });
        var picture = await video.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var sound = await audio.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await client.RequestAsync(new("desktopClose") { SessionID = id });
        Console.WriteLine(JsonSerializer.Serialize(new { authenticated = true, videoBytes = picture.Data.Length, audioFrames = sound.Frames }, Wire.Json));
    }
    await using var reconnected = await WorkspaceClient.ConnectAsync(invitation with { EnrollmentToken = null }, credentials, "Windows receiver fixture");
    await reconnected.RequestAsync(new("ping"));
    return;
}

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
        display: media ? new(new FixtureDisplay()) : null, applications: media ? new(new FixtureApps()) : null, desktop: media ? new(new FixtureDesktop()) : null);
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

sealed class FixtureDesktop : IDesktopHost
{
    public RemoteDesktopDisplay[] Displays() => [new(7, "Main", 1920, 1080, true)];
    public IDesktopCapture Capture(uint? display, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended) => new FixtureDesktopCapture(viewport);
    public void Dispose() { }
}
sealed class FixtureDesktopCapture(AppViewport viewport) : IDesktopCapture
{
    public DisplaySize Display { get; private set; } = viewport.Pixels();
    public uint DisplayID => 7;
    public bool ScreenLocked => false;
    public void Resize(AppViewport viewport) => Display = viewport.Pixels();
    public void Input(AppInput input) { }
    public void Dispose() { }
}
