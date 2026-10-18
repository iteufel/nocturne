import FileProvider
import Combine
import NocturneKit

/// A separate process and socket let Files browse the Mac while the containing app is suspended.
final class HostFileProvider: NSObject {
    let domain: NSFileProviderDomain
    let snapshots: FileProviderSnapshots
    private let account: () throws -> FilesProviderAccount
    private let temporaryDirectory: () throws -> URL
    private let operations = ProviderOperations()
    private let enumeratorLock = NSLock()
    private let enumerators = NSHashTable<FileProviderEnumerator>.weakObjects()
    private var invalidated = false

    init(domain: NSFileProviderDomain, snapshots: FileProviderSnapshots,
         temporaryDirectory: @escaping () throws -> URL = { FileManager.default.temporaryDirectory },
         account: @escaping () throws -> FilesProviderAccount) {
        self.domain = domain; self.snapshots = snapshots; self.temporaryDirectory = temporaryDirectory; self.account = account
        super.init()
    }
    func invalidate() {
        enumeratorLock.lock(); invalidated = true; let active = enumerators.allObjects; enumeratorLock.unlock()
        active.forEach { $0.invalidate() }
        operations.invalidate()
    }

    @MainActor
    func connected<T>(_ body: (WorkspaceConnection) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let credentials = try account()
        guard credentials.domainIdentifier == domain.identifier.rawValue else { throw NSFileProviderError(.notAuthenticated) }
        let connection = WorkspaceConnection(identity: try credentials.identity())
        defer { connection.disconnect() }
        try await connection.connect(credentials.invitation, restoreTerminalSessions: false, rediscover: true)
        guard connection.capabilities.contains("files") else { throw CocoaError(.fileReadNoPermission) }
        return try await body(connection)
    }
    @MainActor
    func list(_ path: String, using connection: WorkspaceConnection) async throws -> [RemoteFile] {
        try SharedFilePath.validate(path)
        var packet = Packet(.list); packet.path = path
        guard let files = try await connection.request(packet).files else { throw NocturneError.invalidFrame }
        try SharedFilePath.validate(files, in: path)
        return files
    }
    @MainActor
    func lookup(_ identifier: NSFileProviderItemIdentifier, using connection: WorkspaceConnection) async throws -> FileProviderItem {
        let path = try FileProviderItem.path(for: identifier)
        if path.isEmpty {
            return FileProviderItem(file: RemoteFile(name: domain.displayName, path: "", isDirectory: true,
                size: 0, modified: Date(timeIntervalSince1970: 0)), root: true)
        }
        let parent = try SharedFilePath.parent(of: path)
        let files = try await list(parent, using: connection)
        try await snapshots.record(files, in: FileProviderItem.identifier(for: parent).rawValue)
        guard let file = files.first(where: { $0.path == path }) else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderItem(file: file)
    }
    @MainActor
    func contents(of container: NSFileProviderItemIdentifier) async throws -> [RemoteFile] {
        if container == .trashContainer { return [] }
        return try await connected { connection in
            if container != .workingSet {
                let path = try FileProviderItem.path(for: container)
                if !path.isEmpty {
                    let item = try await self.lookup(container, using: connection)
                    if !item.file.isDirectory { return [item.file] }
                }
                return try await self.list(path, using: connection)
            }
            // The working set contains visited folders, never an unbounded recursive crawl of the Mac.
            let known = await self.snapshots.knownContainers()
            var paths: Set<String> = [""]
            for key in known {
                guard let path = try? FileProviderItem.path(for: .init(key)) else { continue }
                let parts = path.split(separator: "/")
                for count in 1...max(1, parts.count) where count <= parts.count {
                    paths.insert(parts.prefix(count).joined(separator: "/"))
                }
            }
            var reachable: Set<String> = [""]
            var files: [String: RemoteFile] = [:]
            for path in paths.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
                try Task.checkCancellation()
                guard reachable.contains(path) else { try await self.snapshots.removeSubtree(path); continue }
                let children = try await self.list(path, using: connection)
                try await self.snapshots.record(children, in: FileProviderItem.identifier(for: path).rawValue)
                for child in children {
                    files[child.path] = child
                    if child.isDirectory { reachable.insert(child.path) }
                }
            }
            return files.values.sorted { $0.path < $1.path }
        }
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { _ in
            do { completionHandler(try await self.connected { try await self.lookup(identifier, using: $0) }, nil) }
            catch { completionHandler(nil, providerError(error)) }
        }
    }
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { progress in
            do {
                let result = try await self.connected { connection -> (URL, FileProviderItem) in
                    let item = try await self.lookup(itemIdentifier, using: connection)
                    guard !item.file.isDirectory else { throw NSFileProviderError(.noSuchItem) }
                    if let requestedVersion, requestedVersion != item.itemVersion { throw providerFileChangedError() }
                    progress.totalUnitCount = max(1, item.file.size)
                    let transfer = FileTransferModel()
                    let observation = transfer.$bytesTransferred.sink { progress.completedUnitCount = $0 }
                    defer { observation.cancel() }
                    let url = try await transfer.download(item.file, using: connection, temporaryDirectory: self.temporaryDirectory())
                    do {
                        try Task.checkCancellation()
                        let latest = try await self.lookup(itemIdentifier, using: connection)
                        guard latest.itemVersion == item.itemVersion else { throw providerFileChangedError() }
                        return (url, latest)
                    } catch { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); throw error }
                }
                completionHandler(result.0, result.1, nil)
            } catch { completionHandler(nil, nil, providerError(error)) }
        }
    }
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier != .workingSet, containerItemIdentifier != .trashContainer {
            _ = try FileProviderItem.path(for: containerItemIdentifier)
        }
        let enumerator = FileProviderEnumerator(container: containerItemIdentifier, provider: self)
        enumeratorLock.lock(); enumerators.add(enumerator); let cancelled = invalidated; enumeratorLock.unlock()
        if cancelled { enumerator.invalidate() }
        return enumerator
    }

    private func run(_ body: @escaping @MainActor (Progress) async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = operations.start { await body(progress); progress.completedUnitCount = progress.totalUnitCount }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

/// File Provider can issue concurrent callbacks and invalidate an instance at any time.
final class ProviderOperations {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false
    func start(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        let task = Task { @MainActor in await body(); self.remove(id) }
        tasks[id] = task
        if invalidated { task.cancel() }
        return task
    }
    private func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; tasks.removeValue(forKey: id) }
    func invalidate() {
        lock.lock(); invalidated = true; let active = Array(tasks.values); tasks.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
}
