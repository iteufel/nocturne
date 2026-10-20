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

    public static string Invitation(string host, string name, byte[] secret, byte[] token, RemoteAccessInfo? remote = null)
    {
        if (secret.Length != 32 || token.Length != 32 || !System.Net.IPAddress.TryParse(host, out _))
            throw new ArgumentException("Choose a local network address before pairing.");
        var fields = new Dictionary<string, string>
        {
            ["v"] = remote == null ? "2" : "3", ["host"] = host, ["port"] = Port.ToString(), ["name"] = name,
            ["key"] = Convert.ToBase64String(secret), ["token"] = Convert.ToBase64String(token)
        };
        if (remote != null)
        {
            fields["broker"] = RemoteAccessInfo.ValidateBroker(remote.BrokerURL);
            if (remote.EndpointID.Length != 64 || !remote.EndpointID.All(char.IsAsciiHexDigit))
                throw new ArgumentException("Invalid remote endpoint identity.");
            fields["endpoint"] = remote.EndpointID.ToLowerInvariant();
        }
        return "nocturne://pair?" + string.Join("&", fields.Select(kv => kv.Key + "=" + Uri.EscapeDataString(kv.Value)));
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
    public DisplaySize? Display { get; set; }
    [JsonPropertyName("applicationID")] public string? ApplicationID { get; set; }
    public RemoteApplication[]? Applications { get; set; }
    public RemoteAppWindow[]? Windows { get; set; }
    public RemoteAppWindow? Window { get; set; }
    [JsonPropertyName("windowID")] public uint? WindowID { get; set; }
    public AppViewport? Viewport { get; set; }
    public AppInput? Input { get; set; }
    public AppVideo? Video { get; set; }
    public Packet Reply() => new(Operation) { Id = Id };
}

public sealed record RemoteFile(string Name, string Path, bool IsDirectory, long Size, double Modified);
public sealed record RemoteTerminal(string Id, string Name, bool Running, int Columns, int Rows);
public sealed record HostPermissions(bool Terminal = false, bool Files = false, bool Microphone = false, bool ScreenSharing = true);

public sealed record DisplaySize(int Width, int Height, int FrameRate)
{
    [JsonIgnore] public bool IsValid => Width is >= 320 and <= 4096 && Height is >= 320 and <= 4096 &&
        Width % 2 == 0 && Height % 2 == 0 && FrameRate is 30 or 60 or 120;
}
public sealed record RemoteApplication(string Id, string Name, string? BundleIdentifier = null);
public sealed record RemoteAppWindow(uint Id, [property: JsonPropertyName("applicationID")] string ApplicationID, string Title, int Width, int Height);
public sealed record AppViewport(int Width, int Height, double Scale, int FrameRate = 60)
{
    [JsonIgnore] public bool IsValid => Width is >= 240 and <= 4096 && Height is >= 160 and <= 4096 &&
        double.IsFinite(Scale) && Scale is >= 1 and <= 3 && FrameRate is 30 or 60;
    public DisplaySize Pixels()
    {
        if (!IsValid) throw new IOException("Invalid app window size.");
        var factor = Math.Min(1, 4096 / (Math.Max(Width, Height) * Scale));
        return new((int)Math.Round(Width * Scale * factor / 2) * 2,
            (int)Math.Round(Height * Scale * factor / 2) * 2, FrameRate);
    }
}
public sealed record AppInput(string Kind, double X = 0, double Y = 0, int Button = 0, int? ClickCount = null,
    double DeltaX = 0, double DeltaY = 0, ushort KeyCode = 0, ulong Modifiers = 0, string Text = "")
{
    [JsonIgnore] public bool IsValid => Kind is "move" or "down" or "up" or "scroll" or "keyDown" or "keyUp" or "text" &&
        double.IsFinite(X) && double.IsFinite(Y) && X is >= 0 and <= 1 && Y is >= 0 and <= 1 &&
        Button is >= 0 and <= 2 && (ClickCount ?? 1) is >= 1 and <= 3 && double.IsFinite(DeltaX) && double.IsFinite(DeltaY) &&
        Math.Abs(DeltaX) <= 4096 && Math.Abs(DeltaY) <= 4096 && KeyCode <= 127 && Text != null && Text.Length <= 1024;
}
public sealed record AppVideo(byte[] Data, byte[][] ParameterSets, double Timestamp);

public interface IStreamingEngine
{
    Task PairAsync(string pin, string name, string address, CancellationToken cancellation);
    Task RemoveAsync(string fingerprint, CancellationToken cancellation);
}
