import Foundation
import CryptoKit
import Security

/// The streaming certificate identifies the same device across video, terminal, and files.
/// A fresh server challenge proves possession of its private key on every connection.
public struct WorkspaceIdentity {
    public let certificate: Data
    public let name: String
    public let sign: (Data) throws -> Data
    public init(certificate: Data, name: String, sign: @escaping (Data) throws -> Data) {
        self.certificate = certificate; self.name = name; self.sign = sign
    }
    public static func message(for challenge: Data) -> Data {
        Data("nocturne-workspace-device-v2\0".utf8) + challenge
    }
    public static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }
    public static func verify(certificate: Data, signature: Data, challenge: Data) throws -> String {
        guard challenge.count == 32, certificate.count <= 16_384, signature.count <= 1_024,
              let cert = SecCertificateCreateWithData(nil, certificate as CFData),
              let key = SecCertificateCopyKey(cert),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    message(for: challenge) as CFData, signature as CFData, nil) else {
            throw NocturneError.remote("This device could not be authenticated. Pair it again from Nocturne.")
        }
        return fingerprint(certificate)
    }
}
