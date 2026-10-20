using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using Xunit;

namespace Nocturne.Host.Tests;

public sealed class WorkspaceTests : IAsyncLifetime
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "nocturne-tls-" + Guid.NewGuid());
    private readonly byte[] secret = RandomNumberGenerator.GetBytes(32);
    private readonly DeviceStore store;
    private readonly WorkspaceServer server;
    private readonly List<TestShell> shells = [];
    public WorkspaceTests()
    {
        store = new(Path.Combine(root, "devices.json"));
        server = new("Windows PC", secret, store, new(Terminal: true), null, (_, _) =>
        { var shell = new TestShell(); shells.Add(shell); return shell; }, new TestEngine());
    }
    public Task InitializeAsync() { server.Start(0, IPAddress.Loopback); return Task.CompletedTask; }
    public async Task DisposeAsync() { await server.DisposeAsync(); if (Directory.Exists(root)) Directory.Delete(root, true); }

    [Fact]
    public void RealTlsRequiresKeyCertificateProofAndSingleUseEnrollment()
    {
        using var identity = new Identity();
        using var client = new Client(server.Port, secret);
        var reply = client.Authenticate(identity, store.CreateInvitation());
        Assert.Null(reply.Error); Assert.Equal("Windows PC", reply.Name);
        Assert.Equal(new[] { "terminal", "streaming" }, reply.Capabilities);
        Assert.Null(client.Request(new("ping")).Error);
        using var otherIdentity = new Identity();
        using var uninvited = new Client(server.Port, secret);
        Assert.NotNull(uninvited.Authenticate(otherIdentity, null).Error);
        using var wrongBinding = new Client(server.Port, secret);
        Assert.NotNull(wrongBinding.Authenticate(identity, null, corruptBinding: true).Error);
        using var reconnect = new Client(server.Port, secret);
        Assert.Null(reconnect.Authenticate(identity, null).Error);
        Assert.ThrowsAny<IOException>(() => { using var wrongKey = new Client(server.Port, RandomNumberGenerator.GetBytes(32)); });
    }

    [Fact]
    public async Task DetachedTerminalsAreReplayedAndOnlyRemovedOwnerIsDisconnected()
    {
        using var identityA = new Identity(); using var identityB = new Identity();
        using var a = new Client(server.Port, secret); Assert.Null(a.Authenticate(identityA, store.CreateInvitation()).Error);
        using var b = new Client(server.Port, secret); Assert.Null(b.Authenticate(identityB, store.CreateInvitation()).Error);
        var aTab = a.Request(new("terminalOpen")); var bTab = b.Request(new("terminalOpen"));
        Assert.NotNull(aTab.Terminal); Assert.NotNull(bTab.Terminal);
        Assert.NotNull(b.Request(new("terminalInput") { SessionID = aTab.SessionID, Data = [1] }).Error);
        a.Dispose();
        shells[0].Emit(Encoding.UTF8.GetBytes("finished while away"));
        using var aReconnect = new Client(server.Port, secret); Assert.Null(aReconnect.Authenticate(identityA, null).Error);
        var attached = aReconnect.Request(new("terminalAttach") { SessionID = aTab.SessionID, Offset = 0 });
        Assert.Equal("finished while away", Encoding.UTF8.GetString(attached.Data!));
        Assert.Equal(0, attached.Offset); Assert.Equal(19, attached.Size);
        await server.RemoveDeviceAsync(identityA.Fingerprint, "iPad");
        Assert.True(shells[0].Closed); Assert.False(shells[1].Closed);
        Assert.Null(b.Request(new("ping")).Error);
        Assert.ThrowsAny<IOException>(() => aReconnect.Request(new("ping")));
        using var revoked = new Client(server.Port, secret); Assert.NotNull(revoked.Authenticate(identityA, null).Error);
    }

    [Fact]
    public void TerminalLimitsHistoryAndPermissionRevocation()
    {
        using var identity = new Identity(); using var client = new Client(server.Port, secret);
        Assert.Null(client.Authenticate(identity, store.CreateInvitation()).Error);
        Packet? first = null;
        for (var index = 0; index < Wire.MaximumTerminals; index++)
        { var opened = client.Request(new("terminalOpen")); Assert.Null(opened.Error); first ??= opened; }
        Assert.NotNull(client.Request(new("terminalOpen")).Error);
        var block = new byte[16_384];
        for (var index = 0; index < 34; index++)
        { shells[0].Emit(block); Assert.Equal("terminalOutput", client.Read().Operation); }
        var attach = client.Request(new("terminalAttach") { SessionID = first!.SessionID, Offset = 0 });
        Assert.Equal(Wire.TerminalHistory, attach.Data!.Length); Assert.Equal(32_768, attach.Offset);
        server.UpdatePermissions(new());
        Assert.All(shells, shell => Assert.True(shell.Closed));
        Assert.NotNull(client.Request(new("terminalOpen")).Error);
        Assert.NotNull(client.Request(new("uploadBegin") { Path = "file", Size = 0 }).Error);
    }

    [Fact]
    public void OperationsBeforeAuthenticationAndUnsupportedDisplayAreRejected()
    {
        using var client = new Client(server.Port, secret);
        Assert.NotNull(client.Request(new("terminalOpen")).Error);
        using var identity = new Identity(); Assert.Null(client.Authenticate(identity, store.CreateInvitation()).Error);
        Assert.Contains("fixed video resolution", client.Request(new("displayPrepare")).Error);
    }

    [Fact]
    public async Task AuthenticatedMediaNegotiatesCapabilitiesAndRevocationCleansUpWithoutDisconnectingOtherDevices()
    {
        var microphone = new TestMicrophone(); var display = new TestDisplay(); var remote = new TestRemote();
        await using var media = new WorkspaceServer("Media PC", secret, store, new(Microphone: true), null,
            (_, _) => new TestShell(), new TestEngine(), new(microphone), new(display), remote: remote);
        media.Start(0, IPAddress.Loopback);
        using var identity = new Identity(); using var a = new Client(media.Port, secret);
        var welcome = a.Authenticate(identity, store.CreateInvitation());
        Assert.Equal(new[] { "streaming", "display", "microphone-pcm-v1" }, welcome.Capabilities);
        Assert.Equal(identity.Fingerprint, remote.Authorized);
        using var b = new Client(media.Port, secret); Assert.Null(b.Authenticate(identity, null).Error);
        var started = a.Request(new("microphoneStart")); Assert.NotNull(started.SessionID); Assert.True(microphone.Running);
        Assert.NotNull(b.Request(new("microphoneAudio") { SessionID = started.SessionID, Data = new byte[1920], Offset = 0 }).Error);
        Assert.Null(a.Request(new("microphoneAudio") { SessionID = started.SessionID, Data = new byte[1920], Offset = 0 }).Error);
        var request = new Packet("displayPrepare") { SessionID = Guid.NewGuid().ToString(), Display = new(1920, 1080, 60) };
        Assert.Equal(request.Display, a.Request(request).Display);
        Assert.NotNull(b.Request(new("displayHeartbeat") { SessionID = request.SessionID }).Error);
        media.UpdatePermissions(new(ScreenSharing: false));
        Assert.False(microphone.Running); Assert.True(display.Restored);
        Assert.NotNull(a.Request(new("microphoneStart")).Error); Assert.NotNull(a.Request(request).Error);
        Assert.Null(b.Request(new("ping")).Error);
        await media.RemoveDeviceAsync(identity.Fingerprint, "iPad"); Assert.Equal(identity.Fingerprint, remote.Revoked);
    }

    private sealed class TestMicrophone : IMicrophoneOutput
    {
        public bool Running;
        public void Start() => Running = true;
        public void Write(byte[] pcm) { }
        public void Stop() => Running = false;
        public void Dispose() => Stop();
    }
    private sealed class TestDisplay : IDisplayControl
    {
        public bool Restored;
        public DisplaySize Prepare(DisplaySize size) { Restored = false; return size; }
        public void Restore() => Restored = true;
        public void Dispose() { }
    }
    private sealed class TestRemote : IRemoteHost
    {
        public string? Authorized, Revoked;
        public string EndpointID => new('a', 64);
        public void Authorize(ushort sourcePort, string device) => Authorized = device;
        public void Revoke(string device) => Revoked = device;
        public void Dispose() { }
    }

    private sealed class TestEngine : IStreamingEngine
    {
        public Task PairAsync(string pin, string name, string address, CancellationToken cancellation) => Task.CompletedTask;
        public Task RemoveAsync(string fingerprint, CancellationToken cancellation) => Task.CompletedTask;
    }
    private sealed class TestShell : ITerminal
    {
        public bool Closed;
        public event Action<byte[]>? Output;
        public event Action? Exited;
        public void Start() { }
        public void Emit(byte[] data) => Output?.Invoke(data);
        public void Input(byte[] data) { }
        public void Resize(int columns, int rows) { }
        public void Dispose() { Closed = true; Exited?.Invoke(); }
    }
    private sealed class Identity : IDisposable
    {
        private readonly RSA rsa = RSA.Create(2048);
        private readonly X509Certificate2 cert;
        public byte[] Certificate => cert.RawData;
        public string Fingerprint => Wire.Fingerprint(Certificate);
        public Identity() => cert = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=Nocturne Test", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddHours(-1), DateTimeOffset.UtcNow.AddDays(1));
        public byte[] Sign(byte[] challenge) => rsa.SignData(Encoding.UTF8.GetBytes("nocturne-workspace-device-v2\0").Concat(challenge).ToArray(), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        public void Dispose() { cert.Dispose(); rsa.Dispose(); }
    }
    private sealed class Client : IDisposable
    {
        private readonly TcpClient socket;
        private readonly TlsClientProtocol protocol;
        private readonly ClientPsk psk;
        public Client(int port, byte[] secret)
        {
            socket = new() { ReceiveTimeout = 4000, SendTimeout = 4000 };
            try
            {
                socket.Connect(IPAddress.Loopback, port);
                protocol = new(socket.GetStream()); psk = new(secret); protocol.Connect(psk);
            }
            catch { socket.Dispose(); throw; }
        }
        public Packet Authenticate(Identity identity, byte[]? token, bool corruptBinding = false)
        {
            var hello = Request(new("hello") { Version = Wire.Version });
            var challenge = corruptBinding ? RandomNumberGenerator.GetBytes(32) : psk.Challenge(hello.Data!);
            return Request(new("authenticate") { Name = "iPad", Certificate = identity.Certificate, Signature = identity.Sign(challenge), EnrollmentToken = token });
        }
        public Packet Request(Packet packet)
        {
            protocol.Stream.Write(Wire.Encode(packet));
            while (true) { var reply = Read(); if (reply.Id == packet.Id) return reply; }
        }
        public Packet Read() => Wire.Read(protocol.Stream);
        public void Dispose() => socket.Dispose();
    }
    private sealed class ClientPsk(byte[] secret) : PskTlsClient(new BcTlsCrypto(new SecureRandom()), new BasicTlsPskIdentity("nocturne-v1", secret))
    {
        private byte[] binding = [];
        protected override int[] GetSupportedCipherSuites() => [CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256];
        public override void NotifyHandshakeComplete()
        {
            base.NotifyHandshakeComplete(); binding = m_context.ExportKeyingMaterial(Wire.ExporterLabel, [], 32);
        }
        public byte[] Challenge(byte[] nonce) => SHA256.HashData(nonce.Concat(binding).ToArray());
    }
}
