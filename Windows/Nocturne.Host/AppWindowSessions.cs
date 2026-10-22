namespace Nocturne.Host;

public interface IAppWindowCapture : IDisposable
{
    RemoteAppWindow Window { get; }
    DisplaySize Display { get; }
    void Resize(AppViewport viewport);
    void Input(AppInput input);
}

public interface IAppWindowHost : IDisposable
{
    RemoteApplication[] Applications();
    RemoteAppWindow[] Windows(string? application);
    byte[] Icon(string application);
    RemoteAppWindow[] Launch(string application);
    IAppWindowCapture Capture(string application, uint window, AppViewport viewport,
        Func<Packet, Task> send, Action<Exception> ended);
}

/// Catalog requests cannot launch arbitrary paths, and capture/input leases belong to one socket.
public sealed class AppWindowSessions(IAppWindowHost host, TimeProvider? clock = null) : IDisposable
{
    private sealed class Lease(string id, string device, uint window, Func<Packet, Task> send, long touched)
    {
        public readonly string Id = id, Device = device;
        public readonly uint Window = window;
        public readonly Func<Packet, Task> Send = send;
        public long Touched = touched;
        public IAppWindowCapture? Capture;
    }
    private readonly object gate = new();
    private readonly Dictionary<Guid, Lease> leases = [];
    private readonly TimeProvider clock = clock ?? TimeProvider.System;

    public Packet Handle(Packet packet, Guid connection, string device, Func<Packet, Task> send, Func<bool> connected)
    {
        lock (gate)
        {
            Expire();
            if (!connected()) throw new IOException("The app window connection closed.");
            var reply = packet.Reply();
            switch (packet.Operation)
            {
                case "appList":
                    var apps = host.Applications(); var offset = packet.Offset ?? 0;
                    if (offset < 0 || offset > apps.Length) throw new IOException("Invalid application page.");
                    var end = Math.Min(apps.Length, offset + 64);
                    reply.Applications = apps.Skip((int)offset).Take((int)(end - offset)).ToArray();
                    reply.Offset = end; reply.Eof = end == apps.Length;
                    if (offset == 0) reply.Windows = host.Windows(null); break;
                case "appIcon": reply.Data = host.Icon(Application(packet)); break;
                case "appLaunch": reply.Windows = host.Launch(Application(packet)); break;
                case "appOpen":
                    if (leases.ContainsKey(connection) || !Guid.TryParse(packet.SessionID, out _) || packet.WindowID == null || packet.Viewport?.IsValid != true)
                        throw new IOException("Invalid app window request.");
                    if (leases.Count >= 8 || leases.Values.Count(lease => lease.Device == device) >= 4)
                        throw new IOException("Close an app stream before opening another window.");
                    if (leases.Values.Any(lease => lease.Window == packet.WindowID)) throw new IOException("This window is already streaming. Choose another window.");
                    var opening = new Lease(packet.SessionID!, device, packet.WindowID.Value, send, clock.GetTimestamp());
                    leases.Add(connection, opening);
                    try
                    {
                        var capture = host.Capture(Application(packet), opening.Window, packet.Viewport, async frame =>
                        { frame.SessionID = opening.Id; await send(frame); }, error => End(connection, opening.Id, error));
                        if (!connected()) { capture.Dispose(); throw new IOException("The app window connection closed."); }
                        opening.Capture = capture; reply.SessionID = opening.Id; reply.Window = capture.Window; reply.Display = capture.Display;
                    }
                    catch { Release(connection); throw; }
                    break;
                case "appResize":
                case "appInput":
                case "appHeartbeat":
                    if (!leases.TryGetValue(connection, out var lease) || packet.SessionID != lease.Id || lease.Capture == null)
                        throw new IOException("This app window session is not yours.");
                    lease.Touched = clock.GetTimestamp();
                    if (packet.Operation == "appResize")
                    {
                        if (packet.Viewport?.IsValid != true) throw new IOException("Invalid app window size.");
                        try { lease.Capture.Resize(packet.Viewport); }
                        catch (Exception ex) { End(connection, lease.Id, ex); throw; }
                        reply.Window = lease.Capture.Window; reply.Display = lease.Capture.Display;
                    }
                    else if (packet.Operation == "appInput")
                    {
                        if (packet.Input?.IsValid != true) throw new IOException("Invalid app window input.");
                        lease.Capture.Input(packet.Input);
                    }
                    reply.SessionID = lease.Id; break;
                case "appClose":
                    if (leases.TryGetValue(connection, out var closing) && closing.Id == packet.SessionID) Release(connection);
                    reply.SessionID = packet.SessionID; break;
                default: throw new IOException("Invalid app window request.");
            }
            return reply;
        }
    }
    private static string Application(Packet packet) => packet.ApplicationID is { Length: > 0 and <= 32768 } app ? app : throw new IOException("Choose an application from Apps.");
    private void Release(Guid connection) { if (leases.Remove(connection, out var lease)) lease.Capture?.Dispose(); }
    private void End(Guid connection, string session, Exception error)
    {
        lock (gate)
        {
            if (!leases.TryGetValue(connection, out var lease) || lease.Id != session) return;
            Release(connection);
            _ = lease.Send(new("appEnded") { SessionID = session, Error = error.Message });
        }
    }
    public void Disconnected(Guid connection) { lock (gate) Release(connection); }
    public void Expire()
    {
        lock (gate)
            foreach (var pair in leases.Where(pair => clock.GetElapsedTime(pair.Value.Touched).TotalSeconds >= 20).ToArray())
                End(pair.Key, pair.Value.Id, new IOException("The app window connection expired. Reconnect to continue."));
    }
    public void Stop()
    {
        lock (gate)
        {
            List<Exception> failures = [];
            foreach (var connection in leases.Keys.ToArray())
                try { Release(connection); } catch (Exception error) { failures.Add(error); }
            if (failures.Count != 0) throw new AggregateException("App window cleanup did not complete.", failures);
        }
    }
    public void Dispose() { Stop(); host.Dispose(); }
}
