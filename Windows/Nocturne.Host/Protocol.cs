using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nocturne.Host;

public static class Wire
{
    public const int Version = 4, Port = 48555, MaximumFrame = 1_048_576, ChunkSize = 196_608;
    public const int TerminalHistory = 524_288, MaximumTerminals = 8;
    public const string ExporterLabel = "EXPORTER-Nocturne-Workspace-v2";
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        MaxDepth = 32
    };

    public static byte[] Encode(Packet packet)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(packet, Json);
        if (payload.Length is 0 or > MaximumFrame) throw new IOException("Invalid message size.");
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteInt32BigEndian(frame, payload.Length);
        payload.CopyTo(frame, 4);
        return frame;
    }

    public static Packet Read(Stream stream)
    {
        Span<byte> header = stackalloc byte[4];
        stream.ReadExactly(header);
        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length is <= 0 or > MaximumFrame) throw new IOException("Invalid message size.");
        var body = new byte[length];
        stream.ReadExactly(body);
        Packet packet;
        try { packet = JsonSerializer.Deserialize<Packet>(body, Json) ?? throw new IOException("Invalid message."); }
        catch (JsonException ex) { throw new IOException("Invalid message.", ex); }
        if (string.IsNullOrEmpty(packet.Id) || packet.Id.Length > 128 || string.IsNullOrEmpty(packet.Operation) || packet.Operation.Length > 32)
            throw new IOException("Invalid message.");
        return packet;
    }

    public static string VerifyIdentity(byte[] certificate, byte[] signature, byte[] challenge)
    {
        if (certificate.Length is 0 or > 16_384 || signature.Length is 0 or > 1_024 || challenge.Length != 32)
            throw new IOException("This device could not be authenticated. Scan a new pairing code.");
        using var cert = X509CertificateLoader.LoadCertificate(certificate);
        using var rsa = cert.GetRSAPublicKey();
        var message = Encoding.UTF8.GetBytes("nocturne-workspace-device-v2\0").Concat(challenge).ToArray();
        if (rsa == null || !rsa.VerifyData(message, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
            throw new IOException("This device could not be authenticated. Scan a new pairing code.");
        return Fingerprint(certificate);
    }

    public static string Fingerprint(byte[] certificate) => Convert.ToHexStringLower(SHA256.HashData(certificate));

    public static string Invitation(string host, string name, byte[] secret, byte[] token)
    {
        if (secret.Length != 32 || token.Length != 32 || !System.Net.IPAddress.TryParse(host, out _))
            throw new ArgumentException("Choose a local network address before pairing.");
        return "nocturne://pair?" + string.Join("&", new Dictionary<string, string>
        {
            ["v"] = "2", ["host"] = host, ["port"] = Port.ToString(), ["name"] = name,
            ["key"] = Convert.ToBase64String(secret), ["token"] = Convert.ToBase64String(token)
        }.Select(kv => kv.Key + "=" + Uri.EscapeDataString(kv.Value)));
    }
}

public sealed record Packet(string Operation)
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public int? Version { get; set; }
    public string? Error { get; set; }
    public string? Name { get; set; }
    public string? Path { get; set; }
    public long? Offset { get; set; }
    public long? Size { get; set; }
    public byte[]? Data { get; set; }
    [JsonPropertyName("transferID")] public string? TransferID { get; set; }
    [JsonPropertyName("sessionID")] public string? SessionID { get; set; }
    public RemoteTerminal? Terminal { get; set; }
    public RemoteTerminal[]? Terminals { get; set; }
    public int? Columns { get; set; }
    public int? Rows { get; set; }
    public bool? Eof { get; set; }
    public RemoteFile[]? Files { get; set; }
    public string[]? Capabilities { get; set; }
    public byte[]? Certificate { get; set; }
    public byte[]? Signature { get; set; }
    public byte[]? EnrollmentToken { get; set; }
    public Packet Reply() => new(Operation) { Id = Id };
}

public sealed record RemoteFile(string Name, string Path, bool IsDirectory, long Size, double Modified);
public sealed record RemoteTerminal(string Id, string Name, bool Running, int Columns, int Rows);
public sealed record HostPermissions(bool Terminal = false, bool Files = false);

public interface IStreamingEngine
{
    Task PairAsync(string pin, string name, string address, CancellationToken cancellation);
    Task RemoveAsync(string fingerprint, CancellationToken cancellation);
}
