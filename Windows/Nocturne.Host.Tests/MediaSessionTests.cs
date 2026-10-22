using System.Buffers.Binary;
using System.Text.Json;
using Xunit;

namespace Nocturne.Host.Tests;

public sealed class MediaSessionTests
{
    [Fact]
    public void MicrophoneRejectsForeignConnectionsReplayAndLateStopAndExpiresToSilence()
    {
        var clock = new Clock(); var output = new Microphone();
        using var session = new MicrophoneSession(output, clock);
        var owner = Guid.NewGuid(); var foreign = Guid.NewGuid();
        var first = session.Handle(new("microphoneStart"), owner).SessionID;
        Assert.Throws<IOException>(() => session.Handle(new("microphoneStart"), foreign));
        var audio = new Packet("microphoneAudio") { SessionID = first, Offset = 0, Data = new byte[1920] };
        Assert.Throws<IOException>(() => session.Handle(audio, foreign));
        session.Handle(audio, owner); Assert.Equal(1, output.Writes);
        Assert.Throws<IOException>(() => session.Handle(audio, owner));
        Assert.Throws<IOException>(() => session.Handle(audio with { Offset = 1, Data = new byte[1919] }, owner));
        session.Handle(new("microphoneStop") { SessionID = first }, foreign);
        Assert.True(output.Running);
        clock.Advance(2); session.Expire(); Assert.False(output.Running);
        var second = session.Handle(new("microphoneStart"), foreign).SessionID;
        session.Handle(new("microphoneStop") { SessionID = first }, owner); Assert.True(output.Running);
        session.Disconnected(foreign); Assert.False(output.Running); Assert.NotEqual(first, second);
    }
    [Fact]
    public void DisplayLeaseRestoresOnDisconnectAndCannotBeTakenOrReleasedByAnotherSocket()
    {
        var clock = new Clock(); var output = new Display();
        using var session = new DisplaySession(output, clock);
        var owner = Guid.NewGuid(); var foreign = Guid.NewGuid();
        var request = new Packet("displayPrepare") { SessionID = Guid.NewGuid().ToString(), Display = new(1920, 1080, 60) };
        Assert.Equal(request.Display, session.Handle(request, owner).Display);
        Assert.Throws<IOException>(() => session.Handle(request, foreign));
        Assert.Throws<IOException>(() => session.Handle(request with { SessionID = Guid.NewGuid().ToString() }, owner));
        session.Handle(new("displayRelease") { SessionID = request.SessionID }, foreign);
        Assert.Equal(0, output.Restores);
        session.Handle(request with { Display = new(1080, 1920, 60) }, owner);
        Assert.Equal(2, output.Prepares);
        session.Disconnected(owner); Assert.Equal(1, output.Restores);
        session.Handle(request, foreign); clock.Advance(20); session.Expire(); Assert.Equal(2, output.Restores);
    }
    [Fact]
    public void FailedDisplayPreparationRestoresBeforeAnotherLeaseCanBeAcquired()
    {
        var output = new Display { Reject = true };
        using var session = new DisplaySession(output);
        var request = new Packet("displayPrepare") { SessionID = Guid.NewGuid().ToString(), Display = new(1920, 1080, 60) };
        Assert.Throws<IOException>(() => session.Handle(request, Guid.NewGuid())); Assert.Equal(1, output.Restores);
        output.Reject = false;
        Assert.Null(session.Handle(request, Guid.NewGuid()).Error);
    }
    [Fact]
    public void AppLeasesAreExclusiveBoundedOwnedAndExpired()
    {
        var host = new Apps(); var clock = new Clock();
        using var sessions = new AppWindowSessions(host, clock);
        var owner = Guid.NewGuid(); var foreign = Guid.NewGuid();
        var request = new Packet("appOpen") { ApplicationID = "demo", WindowID = 1, SessionID = Guid.NewGuid().ToString(), Viewport = new(640, 480, 2) };
        Packet Handle(Packet packet, Guid connection, string device = "device") => sessions.Handle(packet, connection, device, _ => Task.CompletedTask, () => true);
        Assert.Equal(1u, Handle(request, owner).Window!.Id);
        Assert.Throws<IOException>(() => Handle(request with { SessionID = Guid.NewGuid().ToString() }, foreign));
        Assert.Throws<IOException>(() => Handle(new("appInput") { SessionID = request.SessionID, Input = new("text", Text: "hello") }, foreign));
        Handle(new("appInput") { SessionID = request.SessionID, Input = new("text", Text: "hello") }, owner);
        Assert.Equal(1, host.Captures[0].Inputs);
        Handle(new("appClose") { SessionID = "stale" }, owner); Assert.False(host.Captures[0].Stopped);
        for (uint i = 2; i <= 4; i++) Handle(request with { SessionID = Guid.NewGuid().ToString(), WindowID = i }, Guid.NewGuid());
        Assert.Throws<IOException>(() => Handle(request with { SessionID = Guid.NewGuid().ToString(), WindowID = 5 }, Guid.NewGuid()));
        clock.Advance(20); sessions.Expire(); Assert.All(host.Captures, capture => Assert.True(capture.Stopped));
        Handle(request, foreign); sessions.Disconnected(foreign); Assert.True(host.Captures[^1].Stopped);
    }
    [Fact]
    public void AppCatalogPaginationAndValidationStayWithinTheSwiftWireFormat()
    {
        using var sessions = new AppWindowSessions(new Apps());
        var connection = Guid.NewGuid();
        var first = sessions.Handle(new("appList"), connection, "device", _ => Task.CompletedTask, () => true);
        Assert.Equal(64, first.Applications!.Length); Assert.False(first.Eof); Assert.Equal(64, first.Offset);
        var last = sessions.Handle(new("appList") { Offset = first.Offset }, connection, "device", _ => Task.CompletedTask, () => true);
        Assert.Equal(6, last.Applications!.Length); Assert.True(last.Eof);
        var packet = new Packet("appOpen") { ApplicationID = "demo", WindowID = 123, Viewport = new(640, 480, 2), Display = new(1280, 960, 60) };
        var json = JsonSerializer.Serialize(packet, Wire.Json);
        Assert.Contains("\"applicationID\"", json); Assert.Contains("\"windowID\"", json); Assert.Contains("\"frameRate\":60", json);
        Assert.DoesNotContain("isValid", json);
        Assert.False(new AppViewport(640, 480, double.NaN).IsValid);
        Assert.False(new AppInput("move", X: double.PositiveInfinity).IsValid);
        Assert.False(new AppInput("unknown").IsValid);
    }
    [Fact]
    public void WindowsH264OutputIsConvertedToAvccWithoutParameterSetsInTheAccessUnit()
    {
        var codec = new H264Frame();
        var frame = codec.Convert([0, 0, 1, 0x65, 9, 8], [0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2], 1.25);
        Assert.Equal(new byte[] { 0x67, 1 }, frame.ParameterSets[0]); Assert.Equal(new byte[] { 0x68, 2 }, frame.ParameterSets[1]);
        Assert.Equal(3, BinaryPrimitives.ReadInt32BigEndian(frame.Data)); Assert.Equal(new byte[] { 0x65, 9, 8 }, frame.Data[4..]);
        Assert.Equal(frame.Data, codec.Convert(frame.Data, [], 1.5).Data);
        Assert.Throws<IOException>(() => codec.Convert([0, 0, 0, 9, 1], [], 2));
    }
    [Theory]
    [InlineData(0, 0x41)] [InlineData(51, 0x08)] [InlineData(55, 0xA2)] [InlineData(123, 0x25)]
    public void AppKeyboardCodesAreTranslatedToWindowsVirtualKeys(ushort mac, ushort windows) => Assert.Equal(windows, AppKeyCodes.Windows(mac));
    private sealed class Clock : TimeProvider
    {
        private long milliseconds;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => milliseconds;
        public void Advance(int seconds) => milliseconds += seconds * 1000;
    }
    private sealed class Microphone : IMicrophoneOutput
    {
        public bool Running; public int Writes;
        public void Start() => Running = true;
        public void Write(byte[] pcm) => Writes++;
        public void Stop() => Running = false;
        public void Dispose() => Stop();
    }
    private sealed class Display : IDisplayControl
    {
        public bool Reject; public int Restores, Prepares;
        public DisplaySize Prepare(DisplaySize size) { Prepares++; if (Reject) throw new IOException("Display failed."); return size; }
        public void Restore() => Restores++;
        public void Dispose() { }
    }
    private sealed class Apps : IAppWindowHost
    {
        public readonly List<Capture> Captures = [];
        public RemoteApplication[] Applications() => Enumerable.Range(0, 70).Select(i => new RemoteApplication(i.ToString(), "App " + i)).ToArray();
        public RemoteAppWindow[] Windows(string? app) => [];
        public byte[] Icon(string app) => [1];
        public RemoteAppWindow[] Launch(string app) => [];
        public IAppWindowCapture Capture(string app, uint window, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended)
        { var capture = new Capture(window); Captures.Add(capture); return capture; }
        public void Dispose() { }
    }
    private sealed class Capture(uint id) : IAppWindowCapture
    {
        public bool Stopped; public int Inputs;
        public RemoteAppWindow Window => new(id, "demo", "Window", 640, 480);
        public DisplaySize Display => new(1280, 960, 60);
        public void Resize(AppViewport viewport) { }
        public void Input(AppInput input) => Inputs++;
        public void Dispose() => Stopped = true;
    }
}
