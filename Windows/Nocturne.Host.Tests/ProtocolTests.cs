using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Nocturne.Host.Tests;

public sealed class ProtocolTests
{
    [Fact]
    public void SwiftPacketFieldNamesAndBase64RoundTrip()
    {
        const string fixture = """{"operation":"terminalAttach","id":"swift-request","sessionID":"shell-1","transferID":"upload-2","data":"aGVsbG8=","offset":7,"terminal":{"id":"shell-1","name":"Terminal 1","running":true,"columns":80,"rows":24}}""";
        var bytes = Encoding.UTF8.GetBytes(fixture);
        using var stream = new MemoryStream();
        Span<byte> header = stackalloc byte[4]; BinaryPrimitives.WriteInt32BigEndian(header, bytes.Length);
        stream.Write(header); stream.Write(bytes); stream.Position = 0;
        var packet = Wire.Read(stream);
        Assert.Equal("shell-1", packet.SessionID); Assert.Equal("upload-2", packet.TransferID);
        Assert.Equal("hello", Encoding.UTF8.GetString(packet.Data!));
        using var encoded = JsonDocument.Parse(Wire.Encode(packet).AsMemory(4));
        Assert.Equal("shell-1", encoded.RootElement.GetProperty("sessionID").GetString());
        Assert.False(encoded.RootElement.TryGetProperty("sessionId", out _));
    }

    [Theory]
    [InlineData(-1)] [InlineData(0)] [InlineData(Wire.MaximumFrame + 1)]
    public void FrameLengthIsBoundedBeforeAllocation(int length)
    {
        var header = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(header, length);
        Assert.Throws<IOException>(() => Wire.Read(new MemoryStream(header)));
    }

    [Fact]
    public void InvitationEncodesNamesAndSecretsWithoutChangingThem()
    {
        var secret = RandomNumberGenerator.GetBytes(32); var token = RandomNumberGenerator.GetBytes(32);
        var invitation = new Uri(Wire.Invitation("192.0.2.10", "Studio PC + Windows", secret, token));
        var query = invitation.Query[1..].Split('&').Select(s => s.Split('=', 2)).ToDictionary(s => s[0], s => Uri.UnescapeDataString(s[1]));
        Assert.Equal("2", query["v"]); Assert.Equal("48555", query["port"]);
        Assert.Equal("Studio PC + Windows", query["name"]); Assert.Equal(secret, Convert.FromBase64String(query["key"]));
        Assert.Equal(token, Convert.FromBase64String(query["token"]));
    }

    [Theory]
    [InlineData("../secret")] [InlineData("/secret")] [InlineData("C:/Windows")] [InlineData("a\\b")]
    [InlineData("file:stream")] [InlineData("NUL.txt")] [InlineData("com1")] [InlineData("COM¹.txt")]
    [InlineData("NUL .txt")]
    [InlineData("x/../y")] [InlineData("x//y")] [InlineData("x.")] [InlineData("x ")]
    [InlineData(".NOCTURNE-upload-secret")] [InlineData("x\u0000y")]
    public void WindowsPathsRejectTraversalStreamsAndDeviceNames(string path) => Assert.Throws<IOException>(() => SharedPath.Components(path));

    [Fact]
    public void OrdinaryUnicodePathsAreRetained() => Assert.Equal(new[] { "Documents", "Grüße.txt" }, SharedPath.Components("Documents/Grüße.txt"));

    [Fact]
    public void EngineUsesItsOwnFilesWithoutAMacEncoder()
    {
        var config = EngineConfiguration.Create("C:\\Users\\Owner\\Nocturne", "PC\n#injected = yes");
        Assert.DoesNotContain("videotoolbox", config); Assert.Contains("system_tray = disabled", config);
        Assert.Contains("dd_configuration_option = disabled", config);
        Assert.Contains("origin_web_ui_allowed = pc", config);
        Assert.DoesNotContain("\ninjected =", config);
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes("passwordsalt"));
        Assert.Equal(Convert.ToHexString(digest.Reverse().ToArray()), EngineConfiguration.CredentialHash("password", "salt"));
    }
}

public sealed class DeviceStoreTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "nocturne-test-" + Guid.NewGuid());
    private string StorePath => Path.Combine(root, "devices.json");
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }
    [Fact]
    public void InvitationsExpireAreSingleUseAndRevocationSurvivesRestart()
    {
        var clock = new Clock(); var store = new DeviceStore(StorePath, clock);
        var expired = store.CreateInvitation(); clock.Now = clock.Now.AddMinutes(6);
        Assert.Throws<IOException>(() => store.Authorize("a", "iPad", expired));
        var token = store.CreateInvitation(); store.Authorize("a", "iPad", token);
        Assert.Throws<IOException>(() => store.Authorize("b", "iPhone", token));
        store.Authorize("b", "iPhone", store.CreateInvitation());
        store.Block("a", "iPad");
        var reloaded = new DeviceStore(StorePath);
        Assert.Throws<IOException>(() => reloaded.Authorize("a", "iPad", reloaded.CreateInvitation()));
        Assert.Equal("iPhone", reloaded.Authorize("b", "iPhone", null).Name);
        reloaded.FinishRemoval("a");
        Assert.Throws<IOException>(() => reloaded.Authorize("a", "iPad", token));
        Assert.False(reloaded.IsAuthorized("a")); Assert.True(reloaded.IsAuthorized("b"));
    }
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
