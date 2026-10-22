namespace Nocturne.Host;

public interface IDesktopCapture : IDisposable
{
    DisplaySize Display { get; }
    uint DisplayID { get; }
    bool ScreenLocked { get; }
    void Resize(AppViewport viewport);
    void Input(AppInput input);
}
public interface IDesktopHost : IDisposable
{
    RemoteDesktopDisplay[] Displays();
    IDesktopCapture Capture(uint? display, AppViewport viewport, Func<Packet, Task> send, Action<Exception> ended);
}

/// Desktop input controls the whole signed-in session. Only one authenticated
/// socket can own it, and stale heartbeats release capture and held keys.
public sealed class DesktopSessions(IDesktopHost host, TimeProvider? clock = null) : IDisposable
{
    private sealed class Lease(Guid connection, string id, Func<Packet, Task> send, long touched)
    {
        public readonly Guid Connection = connection;
        public readonly string Id = id;
        public readonly Func<Packet, Task> Send = send;
        public long Touched = touched;
        public IDesktopCapture? Capture;
    }
    private readonly object gate = new();
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    private Lease? lease;
    public Packet Handle(Packet packet, Guid connection, Func<Packet, Task> send, Func<bool> connected)
    {
        lock (gate)
        {
            Expire();
            if (!connected()) throw new IOException("The desktop connection closed.");
            var reply = packet.Reply();
            if (packet.Operation == "desktopList") { reply.Displays = host.Displays(); return reply; }
            if (packet.Operation == "desktopOpen")
            {
                if (lease != null) throw new IOException("This desktop is already in use. Disconnect the other viewer first.");
                if (!Guid.TryParse(packet.SessionID, out _) || packet.Viewport?.IsValid != true) throw new IOException("Invalid desktop request.");
                var opening = new Lease(connection, packet.SessionID!, send, clock.GetTimestamp()); lease = opening;
                try
                {
                    var capture = host.Capture(packet.DisplayID, packet.Viewport, async frame =>
                    { frame.SessionID = opening.Id; await send(frame); }, error => End(connection, opening.Id, error));
                    if (!connected() || lease != opening) { capture.Dispose(); throw new IOException("The desktop connection closed."); }
                    opening.Capture = capture;
                }
                catch { Stop(); throw; }
            }
            else
            {
                if (lease?.Connection != connection || lease.Id != packet.SessionID || lease.Capture == null)
                    throw new IOException("This desktop session is not yours.");
                lease.Touched = clock.GetTimestamp();
                switch (packet.Operation)
                {
                    case "desktopResize":
                        if (packet.Viewport?.IsValid != true) throw new IOException("Invalid desktop size.");
                        try { lease.Capture.Resize(packet.Viewport); }
                        catch (Exception error) { End(connection, lease.Id, error); throw; } break;
                    case "desktopInput":
                        if (packet.Input?.IsValid != true) throw new IOException("Invalid desktop input.");
                        lease.Capture.Input(packet.Input); break;
                    case "desktopHeartbeat": break;
                    case "desktopClose": reply.SessionID = lease.Id; Stop(); return reply;
                    default: throw new IOException("Invalid desktop request.");
                }
            }
            reply.SessionID = lease!.Id; reply.Display = lease.Capture!.Display;
            reply.DisplayID = lease.Capture.DisplayID; reply.ScreenLocked = lease.Capture.ScreenLocked;
            return reply;
        }
    }
    private void End(Guid connection, string id, Exception error)
    {
        lock (gate)
        {
            if (lease?.Connection != connection || lease.Id != id) return;
            var send = lease.Send; Stop();
            _ = send(new("desktopEnded") { SessionID = id, Error = error.Message });
        }
    }
    public void Disconnected(Guid connection) { lock (gate) if (lease?.Connection == connection) Stop(); }
    public void Expire()
    {
        lock (gate)
            if (lease != null && clock.GetElapsedTime(lease.Touched).TotalSeconds >= 20)
                End(lease.Connection, lease.Id, new IOException("The desktop connection expired. Reconnect to continue."));
    }
    public void Stop() { lock (gate) { var capture = lease?.Capture; lease = null; capture?.Dispose(); } }
    public void Dispose() { Stop(); host.Dispose(); }
}
