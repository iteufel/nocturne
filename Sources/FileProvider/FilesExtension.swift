#if os(iOS)
import FileProvider
import NocturneKit

/// An on-demand Files location. Browsing does not replicate the Mac's folder onto the device.
final class FilesExtension: NSFileProviderExtension {
    private var hostDomain: NSFileProviderDomain {
        domain ?? NSFileProviderDomain(identifier: .init("unpaired"), displayName: "Nocturne", pathRelativeToDocumentStorage: "unpaired")
    }
    private var snapshotsURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HostFiles/" + hostDomain.identifier.rawValue + ".json")
    }
    private let stateLock = NSLock()
    private var cachedMetadata: ProviderMetadataCache?
    private var cachedBackend: HostFileProvider?
    private var metadata: ProviderMetadataCache {
        stateLock.lock(); defer { stateLock.unlock() }
        if let cachedMetadata { return cachedMetadata }
        let cache = ProviderMetadataCache(url: snapshotsURL); cachedMetadata = cache; return cache
    }
    private var backend: HostFileProvider {
        stateLock.lock(); defer { stateLock.unlock() }
        if let cachedBackend { return cachedBackend }
        let provider = HostFileProvider(domain: hostDomain, snapshots: FileProviderSnapshots(url: snapshotsURL)) { [weak self] in
            guard let self else { throw NSFileProviderError(.notAuthenticated) }
            return try self.credentials()
        }
        cachedBackend = provider; return provider
    }
    private let transfersLock = NSLock()
    private var transfers: [URL: Progress] = [:]

    private func credentials() throws -> FilesProviderAccount {
        guard let data = try SecureStore.read(FilesProviderAccount.keychainAccount(domainIdentifier: hostDomain.identifier.rawValue)) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let account = try JSONDecoder().decode(FilesProviderAccount.self, from: data)
        guard account.domainIdentifier == hostDomain.identifier.rawValue else { throw NSFileProviderError(.notAuthenticated) }
        return account
    }
    private var storage: URL {
        NSFileProviderManager.default.documentStorageURL.appendingPathComponent(hostDomain.pathRelativeToDocumentStorage, isDirectory: true)
    }
    override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        _ = try credentials()
        let path = try FileProviderItem.path(for: identifier)
        if path.isEmpty {
            return FileProviderItem(file: RemoteFile(name: hostDomain.displayName, path: "", isDirectory: true, size: 0,
                modified: Date(timeIntervalSince1970: 0)), root: true)
        }
        guard let file = try metadata.file(at: path) else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderItem(file: file)
    }
    override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        _ = try credentials()
        return try backend.enumerator(for: containerItemIdentifier, request: NSFileProviderRequest())
    }
    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        do {
            let item = try self.item(for: identifier)
            if identifier == .rootContainer {
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                return storage
            }
            let path = try FileProviderItem.path(for: identifier)
            let url = storage.appendingPathComponent(path, isDirectory: item.contentType == .folder)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: item.contentType == .folder ? url : directory, withIntermediateDirectories: true)
            return url
        } catch { return nil }
    }
    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        let base = storage.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        if components == base { return .rootContainer }
        guard components.count > base.count, Array(components.prefix(base.count)) == base else { return nil }
        let path = components.dropFirst(base.count).joined(separator: "/")
        guard (try? SharedFilePath.validate(path, allowRoot: false)) != nil else { return nil }
        let identifier = FileProviderItem.identifier(for: path)
        guard let item = try? item(for: identifier), item.filename == components.last else { return nil }
        return identifier
    }
    override func providePlaceholder(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let identifier = persistentIdentifierForItem(at: url) else { throw NSFileProviderError(.noSuchItem) }
            let item = try self.item(for: identifier)
            try NSFileProviderManager.writePlaceholder(at: NSFileProviderManager.placeholderURL(for: url), withMetadata: item)
            completionHandler(nil)
        } catch { completionHandler(providerError(error)) }
    }
    override func startProvidingItem(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let identifier = persistentIdentifierForItem(at: url) else { completionHandler(NSFileProviderError(.noSuchItem)); return }
        if let item = try? item(for: identifier), item.contentType == .folder {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); completionHandler(nil) }
            catch { completionHandler(providerError(error)) }
            return
        }
        let progress = backend.fetchContents(for: identifier, version: nil, request: NSFileProviderRequest()) { downloaded, item, error in
            self.transfersLock.lock(); self.transfers.removeValue(forKey: url); self.transfersLock.unlock()
            if let error { completionHandler(error); return }
            guard let downloaded, let item else { completionHandler(providerError(NocturneError.invalidTransfer)); return }
            defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: downloaded)
                } else { try FileManager.default.moveItem(at: downloaded, to: url) }
                if let date = item.contentModificationDate {
                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                }
                completionHandler(nil)
            } catch { completionHandler(providerError(error)) }
        }
        transfersLock.lock(); transfers[url] = progress; transfersLock.unlock()
    }
    override func stopProvidingItem(at url: URL) {
        transfersLock.lock(); let progress = transfers.removeValue(forKey: url); transfersLock.unlock()
        progress?.cancel()
        guard let identifier = persistentIdentifierForItem(at: url), identifier != .rootContainer,
              let item = try? item(for: identifier), item.contentType != .folder else { return }
        try? FileManager.default.removeItem(at: url)
        providePlaceholder(at: url) { _ in }
    }
    override func itemChanged(at url: URL) {
        // The location is read-only. Discard any unsolicited local edit instead of uploading it.
        stopProvidingItem(at: url)
    }
    deinit { cachedBackend?.invalidate(); transfers.values.forEach { $0.cancel() } }
}

/// Synchronous item lookups are required by the browsing API; reuse the latest validated listing.
private final class ProviderMetadataCache {
    private let url: URL
    private let lock = NSLock()
    private var modified: Date?
    private var files: [String: RemoteFile] = [:]
    init(url: URL) { self.url = url }
    func file(at path: String) throws -> RemoteFile? {
        lock.lock(); defer { lock.unlock() }
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if date != modified {
            let history = try JSONDecoder().decode([String: [FileProviderSnapshots.Snapshot]].self, from: Data(contentsOf: url))
            files = [:]
            for (container, snapshots) in history {
                guard let parent = try? FileProviderItem.path(for: .init(container)), let snapshot = snapshots.last else { continue }
                if snapshot.files.count == 1, snapshot.files[0].path == parent, !snapshot.files[0].isDirectory { continue }
                try SharedFilePath.validate(snapshot.files, in: parent)
                for file in snapshot.files { files[file.path] = file }
            }
            modified = date
        }
        return files[path]
    }
}
#endif
