import FileProvider
import UniformTypeIdentifiers
import Network
import NocturneKit

final class FileProviderItem: NSObject, NSFileProviderItem {
    let file: RemoteFile
    private let root: Bool

    init(file: RemoteFile, root: Bool = false) { self.file = file; self.root = root }

    static func identifier(for path: String) -> NSFileProviderItemIdentifier {
        if path.isEmpty { return .rootContainer }
        return NSFileProviderItemIdentifier("path:" + Data(path.utf8).base64EncodedString())
    }
    static func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
        if identifier == .rootContainer { return "" }
        guard identifier.rawValue.hasPrefix("path:"),
              let data = Data(base64Encoded: String(identifier.rawValue.dropFirst(5))),
              let path = String(data: data, encoding: .utf8), !path.isEmpty,
              Self.identifier(for: path) == identifier else { throw NSFileProviderError(.noSuchItem) }
        try SharedFilePath.validate(path, allowRoot: false)
        return path
    }
    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(for: file.path) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        root ? .rootContainer : Self.identifier(for: file.path.split(separator: "/").dropLast().joined(separator: "/"))
    }
    var filename: String { file.name }
    var contentType: UTType {
        file.isDirectory ? .folder : UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
    }
    var capabilities: NSFileProviderItemCapabilities {
        file.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }
    var documentSize: NSNumber? { file.isDirectory ? nil : NSNumber(value: file.size) }
    var isDownloaded: Bool { file.isDirectory }
    var isMostRecentVersionDownloaded: Bool { file.isDirectory }
    var contentModificationDate: Date? { root ? nil : file.modified }
    var itemVersion: NSFileProviderItemVersion {
        let version = Data("\(file.size):\(file.modified.timeIntervalSince1970.bitPattern):\(file.isDirectory)".utf8)
        return NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
    }
}

func providerError(_ error: Error) -> Error {
    if error is CancellationError { return CocoaError(.userCancelled) }
    if (error as NSError).domain == NSFileProviderErrorDomain { return error }
    if (error as NSError).domain == NSCocoaErrorDomain { return error }
    if error is NWError { return NSFileProviderError(.serverUnreachable) }
    if let error = error as? NocturneError {
        switch error {
        case .disconnected, .timeout: return NSFileProviderError(.serverUnreachable)
        case .permissionDenied: return CocoaError(.fileReadNoPermission)
        case .invalidPath: return NSFileProviderError(.noSuchItem)
        case .remote(let message):
            if message == NocturneError.permissionDenied.localizedDescription { return CocoaError(.fileReadNoPermission) }
            if message == NocturneError.invalidPath.localizedDescription { return NSFileProviderError(.noSuchItem) }
            if message.contains("Pair it again") || message.contains("paired") || message.contains("pairing") || message.contains("being removed") {
                return NSFileProviderError(.notAuthenticated)
            }
        default: break
        }
    }
    return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
        userInfo: [NSLocalizedDescriptionKey: NocturneLocalization.message(error.localizedDescription), NSUnderlyingErrorKey: error])
}

func providerFileChangedError() -> Error {
    NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "The file changed on your Mac. Download it again."])
}
