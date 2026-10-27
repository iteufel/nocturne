import Foundation
import CryptoKit
import NocturneKit

@MainActor
final class RepositoryService {
    let root: URL
    let run: DeveloperCommand.Run
    init(root: URL, run: @escaping DeveloperCommand.Run = DeveloperCommand.run) { self.root = root; self.run = run }
    static func open(_ directory: URL, run: @escaping DeveloperCommand.Run = DeveloperCommand.run) async throws -> RepositoryService {
        let result = try await run("git", ["rev-parse", "--show-toplevel"], directory, nil)
        guard result.code == 0, !result.truncated, let path = String(data: result.data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !path.isEmpty else {
            throw NocturneError.remote("This conversation is outside a Git repository. Start a chat in your project folder on the Mac.")
        }
        return RepositoryService(root: URL(fileURLWithPath: path).resolvingSymlinksInPath(), run: run)
    }
    func git(_ arguments: [String], accepts: Set<Int32> = [0]) async throws -> DeveloperCommandResult {
        let result = try await run("git", ["--no-pager", "--literal-pathspecs"] + arguments, root, nil)
        guard accepts.contains(result.code) else { throw NocturneError.remote("Git could not finish this action. \(result.error)") }
        return result
    }
    func snapshot(scope: GitDiffScope = .working, requestedBase: String? = nil, remoteName: String? = nil) async throws -> RepositorySnapshot {
        async let branchReply = git(["symbolic-ref", "--short", "-q", "HEAD"], accepts: [0, 1])
        async let headReply = git(["rev-parse", "--verify", "HEAD"], accepts: [0, 128])
        async let refsReply = git(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"])
        async let treesReply = worktrees()
        let remotes = (try await git(["remote"])).text.split(separator: "\n").map(String.init)
        let remote = remoteName ?? (remotes.contains("origin") ? "origin" : remotes.first ?? "origin")
        guard remotes.isEmpty || remotes.contains(remote) else { throw NocturneError.invalidFrame }
        async let remoteReply = git(["remote", "get-url", remote], accepts: [0, 2, 128])
        let refs = String((try await refsReply).text.prefix(100_000)).split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
        let base = try await baseReference(requestedBase, branches: refs)
        let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard !status.truncated else { throw NocturneError.remote("Git's change list is too large to load. Narrow the repository or commit some changes on the Mac.") }
        var changes = Self.parseStatus(status.data)
        if scope == .working { changes = changes.filter(\.unstaged) }
        if scope == .staged { changes = changes.filter(\.staged) }
        if scope == .branch {
            guard let base else { throw NocturneError.remote("Choose a base branch to compare changes.") }
            let names = try await git(["diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", base + "...HEAD", "--"])
            guard !names.truncated else { throw NocturneError.remote("This branch comparison has too many files.") }
            changes = Self.parseNames(names.data)
        }
        let branch = (try await branchReply).text.trimmingCharacters(in: .newlines)
        let head = (try await headReply).text.trimmingCharacters(in: .newlines)
        let remoteURL = (try await remoteReply).text.trimmingCharacters(in: .newlines)
        var snapshot = RepositorySnapshot(root: root.path, branch: branch.isEmpty ? "Detached HEAD" : branch,
            head: head.isEmpty ? nil : head, base: base, branches: Array(refs.prefix(500)), worktrees: try await treesReply,
            changes: Array(changes.prefix(500)), forge: ForgeService.parseRemote(remoteURL), truncated: changes.count > 500 || refs.count > 500)
        snapshot.remotes = remotes; snapshot.indexRevision = try await indexRevision(); return snapshot
    }
    func indexRevision() async throws -> String {
        let head = try await git(["rev-parse", "--verify", "HEAD"], accepts: [0, 128])
        let branch = try await git(["symbolic-ref", "--short", "-q", "HEAD"], accepts: [0, 1])
        let staged = try await git(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--raw", "--abbrev=40", "-z"])
        guard !staged.truncated else { throw NocturneError.remote("The staged change list is too large to commit here.") }
        return SHA256.hash(data: head.data + branch.data + staged.data).map { String(format: "%02x", $0) }.joined()
    }
    func commit(message: String, revision: String?) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 16_384,
              revision == (try await indexRevision()) else { throw NocturneError.remote("Staged files or the branch changed. Refresh and review the commit again.") }
        let staged = try await git(["diff", "--cached", "--quiet"], accepts: [0, 1])
        guard staged.code == 1 else { throw NocturneError.remote("Stage the files you want to commit first.") }
        _ = try await git(["commit", "--message", message])
    }
    func push(remote: String, branch: String, head: String?) async throws {
        let snapshot = try await snapshot(remoteName: remote)
        guard snapshot.remotes.contains(remote), !remote.hasPrefix("-"), snapshot.branch == branch,
              snapshot.head != nil, snapshot.head == head, branch != "Detached HEAD" else { throw NocturneError.remote("The branch changed. Refresh before pushing.") }
        _ = try await git(["push", "--set-upstream", "--", remote, "HEAD:refs/heads/" + branch])
    }
    private func baseReference(_ requested: String?, branches: [String]) async throws -> String? {
        if let requested { guard branches.contains(requested) else { throw NocturneError.invalidFrame }; return requested }
        let symbolic = try await git(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], accepts: [0, 1, 128])
        let preferred = symbolic.text.trimmingCharacters(in: .newlines)
        return ([preferred, "origin/main", "origin/master", "main", "master"].first { !$0.isEmpty && branches.contains($0) })
    }
    func diff(_ request: RepositoryRequest) async throws -> RepositoryText {
        guard let path = request.path else { throw NocturneError.invalidPath }; try Self.validatePath(path)
        var paths = [path]
        if let previous = request.previousPath, previous != path { try Self.validatePath(previous); paths.append(previous) }
        var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames"]
        switch request.scope {
        case .agent: throw NocturneError.remote("The agent's latest diff is part of its conversation, not a Git comparison.")
        case .working:
            let status = try await git(["status", "--porcelain=v1", "-z", "--", path])
            if Self.parseStatus(status.data).contains(where: { $0.indexStatus == "?" }) {
                arguments += ["--no-index", "--", "/dev/null", path]
                let result = try await git(arguments, accepts: [0, 1]); return Self.text(path, result)
            }
        case .staged: arguments.append("--cached")
        case .branch:
            let snapshot = try await snapshot(scope: .branch, requestedBase: request.base)
            guard let base = snapshot.base else { throw NocturneError.invalidFrame }; arguments.append(base + "...HEAD")
        }
        arguments += ["--"] + paths
        return Self.text(path, try await git(arguments))
    }
    nonisolated static func text(_ path: String, _ result: DeveloperCommandResult) -> RepositoryText {
        let data = result.data.prefix(DeveloperProtocol.maximumTextBytes)
        // Back up to a UTF-8 boundary instead of inserting a replacement into a diff.
        var bytes = Data(data)
        for _ in 0..<4 { if String(data: bytes, encoding: .utf8) != nil { break }; if !bytes.isEmpty { bytes.removeLast() } }
        return RepositoryText(path: path, text: String(data: bytes, encoding: .utf8) ?? "Binary content",
            truncated: result.truncated || result.data.count > bytes.count)
    }
    func stage(_ path: String, undo: Bool) async throws {
        try Self.validatePath(path)
        if undo {
            var paths = [path]
            let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
            guard !status.truncated else { throw NocturneError.remote("Refresh and review this repository's large change list on your Mac.") }
            if let change = Self.parseStatus(status.data).first(where: { $0.path == path && $0.indexStatus == "R" }), let previous = change.previousPath {
                try Self.validatePath(previous); paths.append(previous)
            }
            let head = try await git(["rev-parse", "--verify", "HEAD"], accepts: [0, 128])
            _ = try await git((head.code == 0 ? ["restore", "--staged", "--"] : ["rm", "--cached", "--"]) + paths)
        } else { _ = try await git(["add", "--", path]) }
    }
    func worktrees() async throws -> [GitWorktree] {
        let reply = try await git(["worktree", "list", "--porcelain", "-z"])
        guard !reply.truncated else { throw NocturneError.invalidFrame }
        var result: [GitWorktree] = [], path = "", branch = "Detached HEAD", locked = false, prunable = false
        for item in reply.data.split(separator: 0, omittingEmptySubsequences: false).map({ String(decoding: $0, as: UTF8.self) }) {
            if item.isEmpty {
                if !path.isEmpty { result.append(GitWorktree(path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, branch: branch, locked: locked, prunable: prunable)) }
                path = ""; branch = "Detached HEAD"; locked = false; prunable = false
            } else if item.hasPrefix("worktree ") { path = String(item.dropFirst(9)) }
            else if item.hasPrefix("branch ") { branch = String(item.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if item.hasPrefix("locked") { locked = true }
            else if item.hasPrefix("prunable") { prunable = true }
        }
        return Array(result.prefix(100))
    }
    func createWorktree(branch: String, base: String, storage: URL? = nil) async throws -> GitWorktree {
        guard !branch.isEmpty, branch.utf8.count <= 200, !branch.hasPrefix("-"), !base.hasPrefix("-"), !branch.contains("\0") else { throw NocturneError.invalidFrame }
        _ = try await git(["check-ref-format", "--branch", branch])
        let snapshot = try await snapshot()
        guard snapshot.branches.contains(base) else { throw NocturneError.remote("Refresh and choose an existing base branch.") }
        let parent = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nocturne/Worktrees")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = parent.appendingPathComponent(UUID().uuidString)
        _ = try await git(["worktree", "add", "-b", branch, "--", destination.path, base])
        return GitWorktree(path: destination.resolvingSymlinksInPath().path, branch: branch)
    }
    nonisolated static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0),
              !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { throw NocturneError.invalidPath }
    }
    nonisolated static func parseStatus(_ data: Data) -> [GitChange] {
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [GitChange] = [], index = 0
        while index < records.count {
            let record = Array(records[index]); index += 1
            guard record.count >= 4, record[2] == " " else { continue }
            let x = String(record[0]), y = String(record[1]), path = String(record.dropFirst(3))
            var previous: String?
            if (x == "R" || x == "C" || y == "R" || y == "C"), index < records.count { previous = records[index]; index += 1 }
            result.append(GitChange(path: path, previousPath: previous, indexStatus: x, worktreeStatus: y))
        }
        return result
    }
    nonisolated static func parseNames(_ data: Data) -> [GitChange] {
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [GitChange] = [], index = 0
        while index + 1 < records.count {
            let status = records[index]; index += 1
            var path = records[index]; index += 1; var previous: String?
            if status.hasPrefix("R") || status.hasPrefix("C"), index < records.count { previous = path; path = records[index]; index += 1 }
            result.append(GitChange(path: path, previousPath: previous, indexStatus: String(status.prefix(1)), worktreeStatus: " "))
        }
        return result
    }
}
