using System.Net;
using System.Security.Cryptography;
using Xunit;
namespace Nocturne.Host.Tests;

public sealed class DesktopClientTests
{
    [Fact]
    public async Task ReceiverAuthenticatesStreamsReconnectsAndRejectsUnenrolledIdentity()
    {
        var path = Path.Combine(Path.GetTempPath(), "nocturne-client-" + Guid.NewGuid());
        var devices = new DeviceStore(Path.Combine(path, "devices.json")); var secret = RandomNumberGenerator.GetBytes(32);
        var host = new Desktop(); var desktop = new DesktopSessions(host);
        await using var server = new WorkspaceServer("Desktop host", secret, devices, new(), null, (_, _) => throw new IOException(), desktop: desktop);
        server.Start(0, IPAddress.Loopback);
        var invitation = new ClientInvitation("127.0.0.1", (ushort)server.Port, "Host", secret, devices.CreateInvitation());
        var identity = ClientCredentials.Create();
        await using (var client = await WorkspaceClient.ConnectAsync(invitation, identity, "Viewer"))
        {
            Assert.Contains("desktop-stream-v1", client.Capabilities); Assert.Null(client.Invitation.EnrollmentToken);
            Assert.Equal("Desktop host", client.Invitation.Name);
            var list = await client.RequestAsync(new("desktopList")); Assert.Equal(7u, Assert.Single(list.Displays!).Id);
            var open = await client.RequestAsync(new("desktopOpen") { SessionID = Guid.NewGuid().ToString(), Viewport = new(800, 600, 1) });
            Assert.Equal(7u, open.DisplayID); Assert.Equal(new(800, 600, 60), open.Display);
            await client.RequestAsync(new("desktopInput") { SessionID = open.SessionID, Input = new("keyDown", KeyCode: 0) }); Assert.Equal(1, host.Last!.Inputs);
            await client.RequestAsync(new("desktopClose") { SessionID = open.SessionID }); Assert.True(host.Last.Disposed);
        }
        Assert.Single(devices.Devices); Assert.False(devices.HasInvitation);
        await using (var reconnect = await WorkspaceClient.ConnectAsync(invitation with { EnrollmentToken = null }, identity, "Viewer"))
            Assert.Null((await reconnect.RequestAsync(new("ping"))).Error);
        await Assert.ThrowsAnyAsync<IOException>(() => WorkspaceClient.ConnectAsync(invitation with { EnrollmentToken = null }, ClientCredentials.Create(), "Intruder"));
        await server.DisposeAsync(); Directory.Delete(path, true);
    }
    [Fact]
    public void DesktopLeaseCannotBeStolenAndReleasesInputOnExpiryAndPermissionStop()
    {
        var clock = new Clock(); var host = new Desktop(); using var desktop = new DesktopSessions(host, clock);
        var owner = Guid.NewGuid(); var other = Guid.NewGuid();
        var request = new Packet("desktopOpen") { SessionID = Guid.NewGuid().ToString(), Viewport = new(800, 600, 1) };
        Packet Send(Packet packet, Guid socket) => desktop.Handle(packet, socket, _ => Task.CompletedTask, () => true);
        var opened = Send(request, owner);
        Assert.Throws<IOException>(() => Send(request, other));
        Assert.Throws<IOException>(() => Send(new("desktopInput") { SessionID = opened.SessionID, Input = new("text", Text: "foreign") }, other));
        Assert.Throws<IOException>(() => Send(new("desktopClose") { SessionID = opened.SessionID }, other));
        var capture = host.Last!; clock.Advance(20); desktop.Expire(); Assert.True(capture.Disposed);
        Send(request, other); desktop.Disconnected(owner); Assert.False(host.Last!.Disposed);
        desktop.Stop(); Assert.True(host.Last.Disposed);
        Send(request, owner); desktop.Disconnected(owner); Assert.True(host.Last.Disposed);
    }
    [Fact]
    public void PairingParserAndVideoAssemblerRejectAmbiguousOrUnboundedData()
    {
        var secret = new byte[32]; var token = new byte[32];
        var uri = Wire.Invitation("192.0.2.1", "Test & PC", secret, token, new("https://broker.example.com", new string('a', 64)));
        var invitation = ClientInvitation.Parse(uri); Assert.Equal("Test & PC", invitation.Name); Assert.Equal(secret, invitation.Secret);
        Assert.Throws<IOException>(() => ClientInvitation.Parse(uri + "&host=evil"));
        Assert.Throws<IOException>(() => ClientInvitation.Parse(uri.Replace("https%3A%2F%2Fbroker.example.com", "http%3A%2F%2Fbroker.example.com")));
        Assert.Throws<IOException>(() => ClientInvitation.Parse(uri.Replace("port=48555", "port=0")));
        var video = new AppVideo([0, 0, 0, 2, 0x65, 9], [[0x67], [0x68]], 1);
        var assembler = new VideoAssembler();
        var first = new Packet("desktopVideo") { TransferID = "one", Offset = 0, Size = 6, Video = video with { Data = video.Data[..3] } };
        Assert.Null(assembler.Receive(first));
        Assert.Throws<IOException>(() => assembler.Receive(first with { Offset = 4 }));
        assembler.Reset(); Assert.Null(assembler.Receive(first));
        var whole = assembler.Receive(first with { Offset = 3, Video = video with { Data = video.Data[3..] } });
        Assert.Equal(video.Data, whole!.Data);
        Assert.Equal(new byte[] { 0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 9 }, VideoAssembler.AnnexB(whole));
        Assert.Throws<IOException>(() => assembler.Receive(first with { Size = long.MaxValue }));
        Assert.False(new DesktopAudio(new byte[8], 4801).IsValid);
    }
    private sealed class Clock : TimeProvider
    {
        private long timestamp;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => timestamp;
        public void Advance(int seconds) => timestamp += seconds * 1000;
    }
    private sealed class Desktop : IDesktopHost
    {
        public Capture? Last;
        public RemoteDesktopDisplay[] Displays() => [new(7, "Main", 1920, 1080, true)];
        public IDesktopCapture Capture(uint? display, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended) => Last = new(viewport.Pixels());
        public void Dispose() { }
    }
    private sealed class Capture(DisplaySize display) : IDesktopCapture
    {
        public DisplaySize Display { get; private set; } = display;
        public uint DisplayID => 7;
        public bool ScreenLocked => false;
        public bool Disposed;
        public int Inputs;
        public void Resize(AppViewport viewport) => Display = viewport.Pixels();
        public void Input(AppInput input) => Inputs++;
        public void Dispose() => Disposed = true;
    }
}
