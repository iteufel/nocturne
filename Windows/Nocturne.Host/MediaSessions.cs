namespace Nocturne.Host;

public interface IMicrophoneOutput : IDisposable
{
    void Start();
    void Write(byte[] pcm);
    void Stop();
}

/// The microphone belongs to one authenticated socket, including its sequence and timeout.
public sealed class MicrophoneSession(IMicrophoneOutput output, TimeProvider? clock = null) : IDisposable
{
    public const int FrameBytes = 1920;
    private readonly object gate = new();
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    private Guid? owner;
    private string? session;
    private long sequence = -1, touched;

    public Packet Handle(Packet packet, Guid connection)
    {
        lock (gate)
        {
            Expire();
            var reply = packet.Reply();
            switch (packet.Operation)
            {
                case "microphoneStart":
                    if (owner != null) throw new IOException("Another microphone is already connected to this PC.");
                    output.Start(); owner = connection; session = Guid.NewGuid().ToString(); sequence = -1;
                    touched = clock.GetTimestamp(); reply.SessionID = session; reply.Name = "Nocturne Microphone";
                    break;
                case "microphoneAudio":
                    if (owner != connection || session == null || packet.SessionID != session) throw new IOException("This microphone session is not yours.");
                    if (packet.Data?.Length != FrameBytes || packet.Offset == null || packet.Offset < 0 || packet.Offset <= sequence)
                        throw new IOException("Invalid microphone audio frame.");
                    try { output.Write(packet.Data); } catch { Stop(); throw; }
                    sequence = packet.Offset.Value; touched = clock.GetTimestamp(); break;
                case "microphoneStop":
                    if (owner == connection && packet.SessionID == session) Stop(); break;
                default: throw new IOException("Invalid microphone request.");
            }
            return reply;
        }
    }
    public void Disconnected(Guid connection) { lock (gate) { if (owner == connection) Stop(); } }
    public void Expire() { lock (gate) { if (owner != null && clock.GetElapsedTime(touched).TotalSeconds >= 2) Stop(); } }
    public void Stop() { lock (gate) { if (owner == null) return; owner = null; session = null; sequence = -1; output.Stop(); } }
    public void Dispose() { Stop(); output.Dispose(); }
}

public interface IDisplayControl : IDisposable
{
    DisplaySize Prepare(DisplaySize size);
    void Restore();
}

/// A display lease cannot be resized or released by another socket or a stale session.
public sealed class DisplaySession(IDisplayControl display, TimeProvider? clock = null) : IDisposable
{
    private readonly object gate = new();
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    private Guid? owner;
    private string? session;
    private DisplaySize? size;
    private long touched;
    public Packet Handle(Packet packet, Guid connection)
    {
        lock (gate)
        {
            Expire(); var reply = packet.Reply();
            if (packet.Operation == "displayPrepare")
            {
                if (packet.Display?.IsValid != true || !Guid.TryParse(packet.SessionID, out _)) throw new IOException("Invalid display request.");
                if (owner != null && (owner != connection || session != packet.SessionID)) throw new IOException("Another device is using display control.");
                try { size = display.Prepare(packet.Display); }
                catch { display.Restore(); owner = null; session = null; size = null; throw; }
                owner = connection; session = packet.SessionID; touched = clock.GetTimestamp();
            }
            else if (packet.Operation == "displayHeartbeat")
            {
                if (owner != connection || session == null || packet.SessionID != session) throw new IOException("This display session is not yours.");
                touched = clock.GetTimestamp();
            }
            else if (packet.Operation == "displayRelease")
            { if (owner == connection && packet.SessionID == session) Stop(); }
            else throw new IOException("Invalid display request.");
            reply.SessionID = packet.SessionID; reply.Display = size; return reply;
        }
    }
    public void Disconnected(Guid connection) { lock (gate) { if (owner == connection) Stop(); } }
    public void Expire() { lock (gate) { if (owner != null && clock.GetElapsedTime(touched).TotalSeconds >= 20) Stop(); } }
    public void Stop() { lock (gate) { if (owner == null) return; display.Restore(); owner = null; session = null; size = null; } }
    public void Dispose() { Stop(); display.Dispose(); }
}
