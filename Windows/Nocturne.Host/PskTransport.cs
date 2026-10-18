using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace Nocturne.Host;

/// Same TLS 1.2 PSK suite and exporter as Network.framework on iOS; no certificate bypass.
public sealed class WorkspaceTlsServer(byte[] secret)
    : PskTlsServer(new BcTlsCrypto(new SecureRandom()), new IdentityManager(secret))
{
    private byte[]? binding;
    protected override int[] GetSupportedCipherSuites() => [CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256];
    // PSK has no server certificate or OCSP response. Advertising certificate status
    // makes Apple's TLS stack reject ServerHello before it can prove the PSK.
    protected override bool AllowCertificateStatus() => false;
    protected override bool AllowMultiCertStatus() => false;
    public override void NotifyHandshakeComplete()
    {
        base.NotifyHandshakeComplete();
        // Bouncy Castle destroys the exporter secret after this callback.
        // Network.framework's create_secret uses an empty exporter context, which
        // RFC 5705 distinguishes from an omitted context (null in Bouncy Castle).
        binding = m_context.ExportKeyingMaterial(Wire.ExporterLabel, [], 32);
    }
    public byte[] BoundChallenge(byte[] nonce) => SHA256.HashData(nonce.Concat(
        binding ?? throw new IOException("The TLS handshake has not completed.")).ToArray());

    private sealed class IdentityManager(byte[] secret) : TlsPskIdentityManager
    {
        public byte[] GetHint() => null!;
        public byte[] GetPsk(byte[] identity) => secret.Length == 32 &&
            CryptographicOperations.FixedTimeEquals(identity, Encoding.UTF8.GetBytes("nocturne-v1"))
                ? (byte[])secret.Clone() : null!;
    }
}
