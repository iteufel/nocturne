import Foundation
import NocturneKit

/// Persist anchors across extension launches. Only metadata for visited folders is retained.
actor FileProviderSnapshots {
    struct Snapshot: Codable {
        let anchor: Data
        let files: [RemoteFile]
        init(files: [RemoteFile]) { anchor = Data(UUID().uuidString.utf8); self.files = files }
    }
    private let url: URL
    private var history: [String: [Snapshot]]

    init(url: URL) {
        self.url = url
        history = (try? JSONDecoder().decode([String: [Snapshot]].self, from: Data(contentsOf: url))) ?? [:]
    }
    func current(_ container: String) throws -> Snapshot {
        if let snapshot = history[container]?.last { return snapshot }
        return try record([], in: container)
    }
    func previous(_ anchor: Data, in container: String) -> Snapshot? {
        history[container]?.first { $0.anchor == anchor }
    }
    @discardableResult
    func record(_ files: [RemoteFile], in container: String) throws -> Snapshot {
        if let last = history[container]?.last, last.files == files { return last }
        let snapshot = Snapshot(files: files)
        history[container] = Array(((history[container] ?? []) + [snapshot]).suffix(4))
        try persist()
        return snapshot
    }
    func knownContainers() -> [String] {
        history.compactMap { key, snapshots in
            // Files also opens enumerators for individual documents to watch their metadata.
            // Those snapshots must not be traversed as directories by the working set.
            if let path = try? FileProviderItem.path(for: .init(key)), let files = snapshots.last?.files,
               files.count == 1, files[0].path == path, !files[0].isDirectory { return nil }
            return key
        }
    }
    func removeSubtree(_ path: String) throws {
        for key in Array(history.keys) {
            guard let candidate = try? FileProviderItem.path(for: .init(key)),
                  candidate == path || candidate.hasPrefix(path + "/") else { continue }
            history.removeValue(forKey: key)
        }
        try persist()
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: url, options: .atomic)
    }
}
