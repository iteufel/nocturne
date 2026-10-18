import Foundation
import Darwin
import NocturneKit

/// Descriptor-relative access prevents traversal and symlink races within the shared root.
public final class SharedFolder {
    public let url: URL
    private let root: Int32
    public init(url: URL) throws {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = Darwin.open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Self.posixError() }
    }
    deinit { Darwin.close(root) }
    public func list(_ path: String) throws -> [RemoteFile] {
        let fd = try directory(path); defer { Darwin.close(fd) }
        guard let dir = fdopendir(dup(fd)) else { throw Self.posixError() }
        defer { closedir(dir) }
        var files: [RemoteFile] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", !name.hasPrefix(".nocturne-upload-") else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { continue }
            let child = path.isEmpty ? name : path + "/" + name
            files.append(RemoteFile(name: name, path: child, isDirectory: kind == S_IFDIR,
                size: Int64(info.st_size), modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
            guard files.count <= 2_000 else { throw NocturneError.remote("This folder has too many items. Use a smaller shared folder.") }
        }
        return files.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func read(_ path: String, offset: Int64) throws -> (data: Data, size: Int64, eof: Bool) {
        guard offset >= 0 else { throw NocturneError.invalidTransfer }
        let (parent, name) = try parentOf(path); defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError() }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, offset <= info.st_size else { throw NocturneError.invalidPath }
        var bytes = [UInt8](repeating: 0, count: WorkspaceProtocol.chunkSize)
        let count = pread(fd, &bytes, bytes.count, off_t(offset))
        guard count >= 0 else { throw Self.posixError() }
        return (Data(bytes.prefix(count)), Int64(info.st_size), offset + Int64(count) >= info.st_size)
    }
    public func beginUpload(path: String, size: Int64) throws -> IncomingTransfer {
        guard size >= 0, size <= 100 * 1_024 * 1_024 * 1_024 else { throw NocturneError.invalidTransfer }
        let (parent, name) = try parentOf(path); defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw NocturneError.remote("A file with this name already exists. Rename the file before sending it.")
        }
        let temporary = ".nocturne-upload-" + UUID().uuidString
        let fd = openat(root, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        return IncomingTransfer(folder: self, path: path, temporary: temporary, fd: fd, expectedSize: size)
    }
    fileprivate func commit(_ transfer: IncomingTransfer) throws {
        let (parent, name) = try parentOf(transfer.path); defer { Darwin.close(parent) }
        guard renameatx_np(root, transfer.temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw Self.posixError() }
    }
    fileprivate func discard(_ temporary: String) { unlinkat(root, temporary, 0) }
    private func components(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4_096 else { throw NocturneError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".nocturne-upload-") }) else { throw NocturneError.invalidPath }
        return path.isEmpty ? [] : parts
    }
    private func directory(_ path: String) throws -> Int32 {
        let parts = try components(path)
        var fd = dup(root)
        guard fd >= 0 else { throw Self.posixError() }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw NocturneError.invalidPath }
            fd = next
        }
        return fd
    }
    private func parentOf(_ path: String) throws -> (Int32, String) {
        let parts = try components(path)
        guard let name = parts.last else { throw NocturneError.invalidPath }
        return (try directory(parts.dropLast().joined(separator: "/")), name)
    }
    fileprivate static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

public final class IncomingTransfer {
    public let id = UUID().uuidString
    public let path: String
    public let expectedSize: Int64
    public private(set) var received: Int64 = 0
    fileprivate let temporary: String
    private let folder: SharedFolder
    private var fd: Int32
    private var committed = false
    fileprivate init(folder: SharedFolder, path: String, temporary: String, fd: Int32, expectedSize: Int64) {
        self.folder = folder; self.path = path; self.temporary = temporary; self.fd = fd; self.expectedSize = expectedSize
    }
    deinit { if fd >= 0 { Darwin.close(fd) }; if !committed { folder.discard(temporary) } }
    public func append(_ data: Data, offset: Int64) throws {
        guard !committed, offset == received, data.count <= WorkspaceProtocol.chunkSize,
              received + Int64(data.count) <= expectedSize else { throw NocturneError.invalidTransfer }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SharedFolder.posixError() }
                written += count
            }
        }
        received += Int64(data.count)
    }
    public func finish() throws {
        guard !committed, received == expectedSize else { throw NocturneError.invalidTransfer }
        guard fsync(fd) == 0 else { throw SharedFolder.posixError() }
        try folder.commit(self); committed = true
        Darwin.close(fd); fd = -1
    }
}
