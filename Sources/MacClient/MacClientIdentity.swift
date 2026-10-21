import Foundation
import Security
import NocturneKit

/// A separate device identity for outgoing Mac connections. Private material is
/// saved in Keychain and never replaces the local server's pairing key.
struct MacClientIdentity: Codable {
    let certificate: Data
    let privateKey: Data
    static let account = "mac-client-identity"

    static func load(read: (String) throws -> Data? = SecureStore.read,
                     write: (Data, String) throws -> Void = { try SecureStore.write($0, account: $1) }) throws -> Self {
        if let data = try read(account) {
            let saved = try JSONDecoder().decode(Self.self, from: data)
            // Refuse corrupt/mismatched credentials instead of replacing the
            // identity and silently invalidating all of this Mac's pairings.
            let challenge = try SecureStore.randomKey()
            let identity = try saved.workspace(name: "Nocturne Mac")
            _ = try WorkspaceIdentity.verify(certificate: saved.certificate,
                signature: identity.sign(WorkspaceIdentity.message(for: challenge)), challenge: challenge)
            return saved
        }
        let created = try generate()
        try write(JSONEncoder().encode(created), account)
        return created
    }
    func workspace(name: String) throws -> WorkspaceIdentity {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKey as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? NocturneError.invalidFrame
        }
        return WorkspaceIdentity(certificate: certificate, name: name) { message in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
                throw error?.takeRetainedValue() as Error? ?? NocturneError.invalidFrame
            }
            return signature as Data
        }
    }
    static func generate() throws -> Self {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privateData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? NocturneError.invalidFrame
        }
        // Minimal self-signed X.509 certificate. Security performs all key
        // generation and RSA/SHA-256 signing; DER only describes the certificate.
        let signatureAlgorithm = der(0x30, Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00]))
        let rsaAlgorithm = der(0x30, Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]))
        let name = der(0x30, der(0x31, der(0x30, Data([0x06,0x03,0x55,0x04,0x03]) + der(0x0c, Data("Nocturne Mac".utf8)))))
        let validity = der(0x30, der(0x18, Data("20200101000000Z".utf8)) + der(0x18, Data("21200101000000Z".utf8)))
        let serial = der(0x02, Data([0]) + (try SecureStore.randomKey()).prefix(16))
        let body = der(0x30, der(0xa0, der(0x02, Data([2]))) + serial + signatureAlgorithm + name + validity + name +
            der(0x30, rsaAlgorithm + der(0x03, Data([0]) + publicData)))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? NocturneError.invalidFrame
        }
        let certificate = der(0x30, body + signatureAlgorithm + der(0x03, Data([0]) + signature))
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else { throw NocturneError.invalidFrame }
        return Self(certificate: certificate, privateKey: privateData)
    }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var count = data.count, bytes: [UInt8] = []
        if count < 128 { bytes = [UInt8(count)] }
        else {
            while count > 0 { bytes.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + data
    }
}
