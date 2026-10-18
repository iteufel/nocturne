import FileProvider
import NocturneKit

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let provider: HostFileProvider
    private let operations = ProviderOperations()
    init(container: NSFileProviderItemIdentifier, provider: HostFileProvider) {
        self.container = container; self.provider = provider
    }
    func invalidate() { operations.invalidate() }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        operations.start {
            do {
                try Task.checkCancellation()
                let files = try await self.provider.contents(of: self.container)
                try Task.checkCancellation()
                try await self.provider.snapshots.record(files, in: self.container.rawValue)
                // Host listings are capped at 2,000 items. Deliver bounded batches in one final page.
                for start in stride(from: 0, to: files.count, by: 100) {
                    observer.didEnumerate(files[start..<min(files.count, start + 100)].map { FileProviderItem(file: $0) })
                }
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        operations.start {
            let snapshot = try? await self.provider.snapshots.current(self.container.rawValue)
            completionHandler(snapshot.map { NSFileProviderSyncAnchor($0.anchor) })
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        operations.start {
            do {
                try Task.checkCancellation()
                guard let previous = await self.provider.snapshots.previous(anchor.rawValue, in: self.container.rawValue) else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let files = try await self.provider.contents(of: self.container)
                try Task.checkCancellation()
                let current = try await self.provider.snapshots.record(files, in: self.container.rawValue)
                let before = Dictionary(uniqueKeysWithValues: previous.files.map { ($0.path, $0) })
                let paths = Set(files.map(\.path))
                let deleted = previous.files.filter { !paths.contains($0.path) }.map { FileProviderItem.identifier(for: $0.path) }
                let updated = files.filter { before[$0.path] != $0 }.map { FileProviderItem(file: $0) }
                for start in stride(from: 0, to: deleted.count, by: 100) {
                    observer.didDeleteItems(withIdentifiers: Array(deleted[start..<min(deleted.count, start + 100)]))
                }
                for start in stride(from: 0, to: updated.count, by: 100) {
                    observer.didUpdate(Array(updated[start..<min(updated.count, start + 100)]))
                }
                observer.finishEnumeratingChanges(upTo: .init(current.anchor), moreComing: false)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
    }
}
