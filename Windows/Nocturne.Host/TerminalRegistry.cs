namespace Nocturne.Host;

public interface ITerminal : IDisposable
{
    event Action<byte[]>? Output;
    event Action? Exited;
    void Start();
    void Input(byte[] data);
    void Resize(int columns, int rows);
}

/// Terminals belong to an authenticated device, and survive the loss of a socket.
public sealed class TerminalRegistry(Func<int, int, ITerminal> create) : IDisposable
{
    private sealed class Entry(string owner, int number, ITerminal shell, RemoteTerminal info)
    {
        public readonly string Owner = owner;
        public readonly int Number = number;
        public readonly ITerminal Shell = shell;
        public RemoteTerminal Info = info;
        public byte[] History = [];
        public long Offset;
        public readonly Dictionary<Guid, Action<Packet>> Subscribers = [];
    }

    private readonly object gate = new();
    private readonly Dictionary<string, Entry> entries = [];
    private readonly Dictionary<string, int> numbers = [];

    public void Handle(Packet packet, string owner, Guid connection, Action<Packet> send)
    {
        lock (gate)
        {
            var reply = packet.Reply();
            if (packet.Operation == "terminalList")
            {
                reply.Terminals = entries.Values.Where(e => e.Owner == owner).OrderBy(e => e.Number).Select(e => e.Info).ToArray();
                send(reply); return;
            }
            if (packet.Operation == "terminalOpen")
            {
                if (entries.Values.Count(e => e.Owner == owner) >= Wire.MaximumTerminals)
                    throw new IOException("You can have up to eight terminal tabs. Close a tab before opening another.");
                var columns = Math.Clamp(packet.Columns ?? 80, 20, 500);
                var rows = Math.Clamp(packet.Rows ?? 24, 5, 200);
                var shell = create(columns, rows);
                var number = numbers.GetValueOrDefault(owner) + 1; numbers[owner] = number;
                var id = Guid.NewGuid().ToString();
                var entry = new Entry(owner, number, shell, new(id, $"Terminal {number}", true, columns, rows));
                shell.Output += data => Received(id, data);
                shell.Exited += () => Exited(id);
                entry.Subscribers[connection] = send; entries[id] = entry;
                try
                {
                    // Start creates the child before acknowledging; readers deliver on another thread.
                    shell.Start();
                    reply.Terminal = entry.Info; reply.SessionID = id;
                    send(reply);
                }
                catch { entries.Remove(id); shell.Dispose(); throw; }
                return;
            }
            if (packet.SessionID == null || !entries.TryGetValue(packet.SessionID, out var target) || target.Owner != owner)
                throw new IOException("This terminal session is no longer available.");
            reply.SessionID = target.Info.Id;
            switch (packet.Operation)
            {
                case "terminalAttach":
                    var first = target.Offset - target.History.Length;
                    var requested = packet.Offset ?? 0;
                    var start = requested >= first && requested <= target.Offset ? requested : first;
                    reply.Offset = start; reply.Size = target.Offset; reply.Terminal = target.Info;
                    reply.Data = target.History.AsSpan((int)(start - first)).ToArray();
                    target.Subscribers[connection] = send;
                    break;
                case "terminalInput":
                    var data = packet.Data ?? [];
                    if (data.Length > Wire.ChunkSize) throw new IOException("Terminal input is too large.");
                    target.Shell.Input(data);
                    break;
                case "terminalResize":
                    var columns = Math.Clamp(packet.Columns ?? 80, 20, 500);
                    var rows = Math.Clamp(packet.Rows ?? 24, 5, 200);
                    target.Shell.Resize(columns, rows);
                    target.Info = target.Info with { Columns = columns, Rows = rows };
                    break;
                case "terminalClose": Close(target); break;
                default: throw new IOException("Invalid terminal operation.");
            }
            // Replay and subscription are serialized with output: no gaps or duplicate bytes.
            send(reply);
        }
    }

    public void Detach(Guid connection)
    {
        lock (gate) foreach (var entry in entries.Values) entry.Subscribers.Remove(connection);
    }

    public void CloseAll(string? owner = null)
    {
        lock (gate)
        {
            foreach (var entry in entries.Values.Where(e => owner == null || e.Owner == owner).ToArray()) Close(entry);
            if (owner == null) numbers.Clear(); else numbers.Remove(owner);
        }
    }

    private void Close(Entry entry)
    {
        entries.Remove(entry.Info.Id);
        // Native disposal schedules its drain/close separately and never waits on callbacks under this lock.
        entry.Shell.Dispose();
        foreach (var send in entry.Subscribers.Values.ToArray()) send(new("terminalClosed") { SessionID = entry.Info.Id });
    }

    private void Received(string id, byte[] data)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(id, out var entry)) return;
            var packet = new Packet("terminalOutput") { SessionID = id, Offset = entry.Offset, Data = data };
            entry.Offset += data.Length;
            var retained = entry.History.Concat(data).ToArray();
            entry.History = retained.Length > Wire.TerminalHistory ? retained[^Wire.TerminalHistory..] : retained;
            foreach (var send in entry.Subscribers.Values.ToArray()) send(packet);
        }
    }

    private void Exited(string id)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(id, out var entry)) return;
            entry.Info = entry.Info with { Running = false };
            foreach (var send in entry.Subscribers.Values.ToArray())
                send(new("terminalExit") { SessionID = id, Terminal = entry.Info });
        }
    }

    public void Dispose() => CloseAll();
}
