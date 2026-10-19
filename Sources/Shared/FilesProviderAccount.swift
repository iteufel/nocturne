import Foundation
import CryptoKit
import Security

/// Only the app and its Files extension can read this account from their shared Keychain group.
/// Enrollment tokens are deliberately omitted: Files can reconnect an enrolled device, never enroll one.
public struct FilesProviderAccount: Codable {
    /// The single-Mac account saved by earlier versions.
    public static let legacyKeychainAccount = "files-provider"
    /// Each paired Mac is its own Files location, and its extension may read only that location's account.
    public static func keychainAccount(domainIdentifier: String) -> String { "files-provider." + domainIdentifier }
    public static func domainIdentifier(secret: Data) -> String {
        "host-files-" + SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }
    public let invitation: PairingInvitation
    public let certificate: Data
    public let privateKey: Data
    public let deviceName: String
    public var domainIdentifier: String { Self.domainIdentifier(secret: invitation.secret) }
    public var keychainAccount: String { Self.keychainAccount(domainIdentifier: domainIdentifier) }

    public init(invitation: PairingInvitation, certificate: Data, privateKey: Data, deviceName: String) throws {
        self.invitation = try PairingInvitation(host: invitation.host, port: invitation.port,
            name: invitation.name, secret: invitation.secret, remoteAccess: invitation.remoteAccess)
        self.certificate = certificate; self.privateKey = privateKey; self.deviceName = deviceName
        // Catch an invalid export or mismatched certificate before publishing a Files location.
        let identity = try identity()
        let challenge = try SecureStore.randomKey()
        _ = try WorkspaceIdentity.verify(certificate: certificate,
            signature: identity.sign(WorkspaceIdentity.message(for: challenge)), challenge: challenge)
    }

    public func identity() throws -> WorkspaceIdentity {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKey as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NocturneError.invalidFrame as Error
        }
        return WorkspaceIdentity(certificate: certificate, name: deviceName) { message in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
                throw error?.takeRetainedValue() ?? NocturneError.invalidFrame as Error
            }
            return signature as Data
        }
    }
}

/// Canonical relative paths shared by the provider's identifiers, metadata, and downloads.
public enum SharedFilePath {
    public static func validate(_ path: String, allowRoot: Bool = true) throws {
        guard !path.utf8.contains(0), path.utf8.count <= 4_096 else { throw NocturneError.invalidPath }
        if path.isEmpty, allowRoot { return }
        guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".nocturne-upload-")
        }) else { throw NocturneError.invalidPath }
    }
    public static func parent(of path: String) throws -> String {
        try validate(path, allowRoot: false)
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }
    public static func validate(_ files: [RemoteFile], in parent: String) throws {
        try validate(parent)
        guard files.count <= 2_000, Set(files.map(\.path)).count == files.count else { throw NocturneError.invalidFrame }
        for file in files {
            try validate(file.path, allowRoot: false)
            guard try self.parent(of: file.path) == parent,
                  file.name == file.path.split(separator: "/").last.map(String.init), file.size >= 0,
                  file.modified.timeIntervalSince1970.isFinite else { throw NocturneError.invalidFrame }
        }
    }
}
