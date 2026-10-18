using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Nocturne.Host;

public sealed record Device(string Id, string Name, DateTimeOffset LastSeen);

/// Public certificates identify devices; knowing the transport key alone never enrolls one.
public sealed class DeviceStore
{
    private sealed record Snapshot(Dictionary<string, Device> Devices, Dictionary<string, string> Removing);
    private readonly object gate = new();
    private readonly string path;
    private readonly TimeProvider clock;
    private Snapshot snapshot;
    private byte[]? invitation;
    private DateTimeOffset expires;

    public DeviceStore(string path, TimeProvider? clock = null)
    {
        this.path = path;
        this.clock = clock ?? TimeProvider.System;
        snapshot = File.Exists(path)
            ? JsonSerializer.Deserialize<Snapshot>(File.ReadAllBytes(path), Wire.Json) ?? throw new IOException("The device list is invalid.")
            : new([], []);
    }

    public Device[] Devices { get { lock (gate) return snapshot.Devices.Values.ToArray(); } }
    public Dictionary<string, string> PendingRemovals { get { lock (gate) return new(snapshot.Removing); } }
    public bool HasInvitation { get { lock (gate) return invitation != null && expires > clock.GetUtcNow(); } }
    public bool IsAuthorized(string id) { lock (gate) return snapshot.Devices.ContainsKey(id) && !snapshot.Removing.ContainsKey(id); }

    public byte[] CreateInvitation()
    {
        lock (gate)
        {
            invitation = RandomNumberGenerator.GetBytes(32);
            expires = clock.GetUtcNow().AddMinutes(5);
            return (byte[])invitation.Clone();
        }
    }

    public void CancelInvitation() { lock (gate) invitation = null; }

    public Device Authorize(string id, string name, byte[]? token)
    {
        lock (gate)
        {
            if (snapshot.Removing.ContainsKey(id)) throw new IOException("This device is being removed. Retry removal on the computer.");
            var enrolling = token?.Length == 32 && invitation != null && expires > clock.GetUtcNow()
                && CryptographicOperations.FixedTimeEquals(token, invitation);
            if (!snapshot.Devices.ContainsKey(id) && !enrolling)
                throw new IOException("This device is no longer paired. Scan a new code in Nocturne Server.");
            name = name.Trim();
            if (name.Length == 0 || Encoding.UTF8.GetByteCount(name) > 128 || name.Any(char.IsControl))
                throw new IOException("Invalid device name.");
            var device = new Device(id, name, clock.GetUtcNow());
            var next = new Dictionary<string, Device>(snapshot.Devices) { [id] = device };
            Save(new(next, new(snapshot.Removing)));
            if (enrolling) invitation = null;
            return device;
        }
    }

    public void Block(string id, string name)
    {
        lock (gate)
        {
            invitation = null;
            // A failed disk write must still block the identity for this process.
            snapshot.Removing[id] = name;
            Save(snapshot);
        }
    }

    public void FinishRemoval(string id)
    {
        lock (gate)
        {
            var devices = new Dictionary<string, Device>(snapshot.Devices); devices.Remove(id);
            var removing = new Dictionary<string, string>(snapshot.Removing); removing.Remove(id);
            Save(new(devices, removing));
        }
    }

    private void Save(Snapshot next)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(next, Wire.Json));
        File.Move(temporary, path, true);
        snapshot = next;
    }
}
