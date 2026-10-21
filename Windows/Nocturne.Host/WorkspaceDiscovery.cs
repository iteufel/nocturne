using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
namespace Nocturne.Host;

/// DNS-SD locates candidates only. Every discovered address still goes through
/// TLS-PSK and the certificate proof; no secret or enrollment token is broadcast.
public static class WorkspaceDiscovery
{
    public const string Service = "_nocturne._tcp.local";
    private static readonly IPEndPoint Group = new(IPAddress.Parse("224.0.0.251"), 5353);
    public static string Identifier(byte[] secret) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("nocturne-discovery-v1\0").Concat(secret).ToArray()));
    public sealed record Record(string Name, ushort Type, byte[] Data, string? Target = null, ushort Port = 0);
    public static Record[] Parse(byte[] packet)
    {
        if (packet.Length < 12 || packet.Length > 9000) throw new IOException("Invalid discovery message.");
        ushort Number(int at) => BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(at));
        var questions = Number(4); var count = Number(6) + Number(8) + Number(10);
        if (questions + count > 128) throw new IOException("Invalid discovery record count.");
        var offset = 12;
        string Name(ref int cursor)
        {
            var labels = new List<string>(); var position = cursor; var jumped = false; var steps = 0; var length = 0;
            while (true)
            {
                if (position >= packet.Length || ++steps > 128) throw new IOException("Invalid discovery name.");
                var size = packet[position++];
                if ((size & 0xc0) == 0xc0)
                {
                    if (position >= packet.Length) throw new IOException("Invalid discovery pointer.");
                    var pointer = ((size & 0x3f) << 8) | packet[position++];
                    if (pointer >= position - 2) throw new IOException("Invalid discovery pointer.");
                    if (!jumped) cursor = position; jumped = true; position = pointer; continue;
                }
                if (size == 0) { if (!jumped) cursor = position; return string.Join('.', labels); }
                if (size > 63 || position + size > packet.Length || (length += size + 1) > 255) throw new IOException("Invalid discovery label.");
                labels.Add(Encoding.UTF8.GetString(packet, position, size)); position += size;
            }
        }
        for (var index = 0; index < questions; index++) { _ = Name(ref offset); offset += 4; if (offset > packet.Length) throw new IOException("Invalid discovery question."); }
        var records = new List<Record>();
        for (var index = 0; index < count; index++)
        {
            var name = Name(ref offset);
            if (offset + 10 > packet.Length) throw new IOException("Invalid discovery record.");
            var type = Number(offset); var length = Number(offset + 8); offset += 10;
            if (offset + length > packet.Length) throw new IOException("Invalid discovery record data.");
            string? target = null; ushort port = 0; var cursor = offset;
            if (type == 33 && length >= 7) { port = Number(offset + 4); cursor += 6; target = Name(ref cursor); }
            if (type == 12) target = Name(ref cursor);
            if (cursor > offset + length) throw new IOException("Invalid discovery target.");
            records.Add(new(name, type, packet[offset..(offset + length)], target, port)); offset += length;
        }
        return records.ToArray();
    }
    public static async Task<(string Host, ushort Port)?> FindAsync(byte[] secret, CancellationToken cancellation)
    {
        try
        {
            using var socket = new UdpClient(AddressFamily.InterNetwork);
            socket.Client.Bind(new IPEndPoint(IPAddress.Any, 0));
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromSeconds(2));
            var query = new MemoryStream(); query.Write(new byte[12]); WriteName(query, Service); Number(query, 12); Number(query, 0x8001);
            var bytes = query.ToArray(); bytes[5] = 1;
            foreach (var address in Addresses())
            {
                try { socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes()); await socket.SendAsync(bytes, Group, deadline.Token); }
                catch (SocketException) { }
            }
            var records = new List<Record>(); var id = Identifier(secret);
            while (!deadline.IsCancellationRequested)
            {
                var response = await socket.ReceiveAsync(deadline.Token);
                try { records.AddRange(Parse(response.Buffer)); } catch (IOException) { continue; }
                if (records.Count > 512) records.RemoveRange(0, records.Count - 512);
                foreach (var txt in records.Where(record => record.Type == 16 && HasIdentifier(record.Data, id)))
                {
                    var srv = records.LastOrDefault(record => record.Type == 33 && Same(record.Name, txt.Name) && record.Port > 0);
                    var address = records.LastOrDefault(record => record.Type == 1 && record.Data.Length == 4 && Same(record.Name, srv?.Target));
                    if (srv != null && address != null) return (new IPAddress(address.Data).ToString(), srv.Port);
                }
            }
        }
        catch (Exception error) when (error is SocketException or IOException or OperationCanceledException) { cancellation.ThrowIfCancellationRequested(); }
        return null;
    }
    private static bool Same(string? left, string? right) => string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    private static bool HasIdentifier(byte[] data, string id)
    {
        for (var offset = 0; offset < data.Length;)
        {
            var size = data[offset++]; if (size > data.Length - offset) return false;
            if (Encoding.UTF8.GetString(data, offset, size) == "id=" + id) return true; offset += size;
        }
        return false;
    }
    internal static IPAddress[] Addresses() => NetworkInterface.GetAllNetworkInterfaces().Where(network => network.OperationalStatus == OperationalStatus.Up)
        .SelectMany(network => network.GetIPProperties().UnicastAddresses).Select(value => value.Address)
        .Where(address => address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address) && address.GetAddressBytes()[0] != 169).Distinct().Take(16).ToArray();
    private static void Number(Stream stream, int value) { Span<byte> bytes = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(bytes, (ushort)value); stream.Write(bytes); }
    private static void WriteName(Stream stream, string name)
    {
        foreach (var label in name.Split('.')) { var bytes = Encoding.UTF8.GetBytes(label); stream.WriteByte((byte)bytes.Length); stream.Write(bytes); } stream.WriteByte(0);
    }
    public static byte[] Announcement(string id, ushort port, IPAddress[] addresses, bool goodbye = false)
    {
        if (id.Length != 64 || !id.All(char.IsAsciiHexDigit) || addresses.Length > 16) throw new ArgumentException("Invalid discovery identity.");
        var host = "nocturne-" + id[..16] + ".local"; var instance = "Nocturne-" + id[..16] + "." + Service;
        using var output = new MemoryStream(); output.Write(new byte[12]);
        void Record(string name, int type, Action<Stream> write)
        {
            using var body = new MemoryStream(); write(body); WriteName(output, name); Number(output, type); Number(output, type == 12 ? 1 : 0x8001);
            output.Write(new byte[] { 0, 0, 0, goodbye ? (byte)0 : (byte)120 }); Number(output, (int)body.Length); body.Position = 0; body.CopyTo(output);
        }
        Record(Service, 12, stream => WriteName(stream, instance));
        Record(instance, 33, stream => { Number(stream, 0); Number(stream, 0); Number(stream, port); WriteName(stream, host); });
        Record(instance, 16, stream => { var text = Encoding.UTF8.GetBytes("id=" + id); stream.WriteByte((byte)text.Length); stream.Write(text); });
        foreach (var address in addresses) { if (address.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("IPv4 address required."); Record(host, 1, stream => stream.Write(address.GetAddressBytes())); }
        var bytes = output.ToArray(); bytes[2] = 0x84; bytes[7] = (byte)(3 + addresses.Length); return bytes;
    }
    public sealed class Advertisement : IDisposable
    {
        private readonly UdpClient socket;
        private readonly string id;
        private readonly ushort port;
        private readonly CancellationTokenSource lifetime = new();
        private readonly Task worker;
        private readonly Timer timer;
        private readonly object sends = new();
        public Advertisement(byte[] secret, ushort port)
        {
            id = Identifier(secret); this.port = port; socket = new(AddressFamily.InterNetwork);
            socket.Client.ExclusiveAddressUse = false; socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            socket.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
            foreach (var address in Addresses()) try { socket.JoinMulticastGroup(Group.Address, address); } catch (SocketException) { }
            worker = Task.Run(Listen); timer = new(_ => Announce(), null, 0, 60000);
        }
        private void Announce()
        {
            if (lifetime.IsCancellationRequested) return;
            lock (sends)
            try
            {
                var addresses = Addresses(); var bytes = Announcement(id, port, addresses);
                foreach (var address in addresses)
                {
                    socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes()); socket.Send(bytes, Group);
                }
            }
            catch (Exception error) when (error is SocketException or ObjectDisposedException) { }
        }
        private async Task Listen()
        {
            try
            {
                while (!lifetime.IsCancellationRequested)
                {
                    var query = await socket.ReceiveAsync(lifetime.Token);
                    if (query.Buffer.Length is < 12 or > 9000 || (query.Buffer[2] & 0x80) != 0) continue;
                    // Answers are bounded and contain only this service. Ignore
                    // unrelated mDNS traffic rather than reflecting it.
                    if (!Encoding.UTF8.GetString(query.Buffer).Contains("_nocturne", StringComparison.Ordinal)) continue;
                    var bytes = Announcement(id, port, Addresses());
                    if (query.RemoteEndPoint.Port == 5353) Announce();
                    else await socket.SendAsync(bytes, query.RemoteEndPoint, lifetime.Token);
                }
            }
            catch (Exception error) when (error is SocketException or ObjectDisposedException or OperationCanceledException) { }
        }
        public void Dispose() { lifetime.Cancel(); timer.Dispose(); try { socket.Send(Announcement(id, port, Addresses(), true), Group); } catch (SocketException) { } socket.Dispose(); }
    }
}
