import XCTest
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class DeveloperWorkspaceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nocturne-developer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func git(_ arguments: [String], at root: URL? = nil) async throws -> String {
        let result = try await DeveloperCommand.run("git", arguments, root ?? directory, nil)
        guard result.code == 0 else { XCTFail(result.error); throw NocturneError.remote(result.error) }
        return result.text
    }
    private func repository() async throws -> RepositoryService {
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "Nocturne test"]); _ = try await git(["config", "user.email", "test@example.invalid"])
        _ = try await git(["config", "commit.gpgsign", "false"]); _ = try await git(["config", "core.hooksPath", "/dev/null"])
        try "original\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "notes.txt"]); _ = try await git(["commit", "-m", "Fixture"])
        return try await RepositoryService.open(directory)
    }
    func testRealGitStatusStagingAndDiffPreserveUnrelatedFiles() async throws {
        let repository = try await repository()
        try "changed\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let odd = "line\nname [a].txt"
        try "untracked\n".write(to: directory.appendingPathComponent(odd), atomically: true, encoding: .utf8)
        let first = try await repository.snapshot()
        XCTAssertEqual(Set(first.changes.map(\.path)), ["notes.txt", odd])
        var request = RepositoryRequest(.diff); request.path = "notes.txt"
        let patch = try await repository.diff(request)
        XCTAssertTrue(patch.text.contains("-original")); XCTAssertTrue(patch.text.contains("+changed"))
        try await repository.stage("notes.txt", undo: false)
        let staged = try await repository.snapshot(scope: .staged)
        XCTAssertEqual(staged.changes.map(\.path), ["notes.txt"])
        let working = try await repository.snapshot(); XCTAssertEqual(working.changes.map(\.path), [odd])
        request.scope = .staged; let stagedPatch = try await repository.diff(request); XCTAssertTrue(stagedPatch.text.contains("+changed"))
        try await repository.stage("notes.txt", undo: true)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(odd), encoding: .utf8), "untracked\n")
        let empty = try await repository.snapshot(scope: .staged); XCTAssertTrue(empty.changes.isEmpty)
    }
    func testWorktreeCreationDoesNotMoveDirtyCheckoutAndBranchComparisonUsesBase() async throws {
        let repository = try await repository()
        try "dirty parent\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let tree = try await repository.createWorktree(branch: "feature/voice", base: "main", storage: directory.appendingPathComponent("worktrees"))
        let location = URL(fileURLWithPath: tree.path)
        XCTAssertEqual(try String(contentsOf: location.appendingPathComponent("notes.txt"), encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8), "dirty parent\n")
        let parentBranch = try await git(["branch", "--show-current"]); XCTAssertEqual(parentBranch, "main\n")
        try "feature\n".write(to: location.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "notes.txt"], at: location); _ = try await git(["commit", "-m", "Feature"], at: location)
        let child = try await RepositoryService.open(location)
        let comparison = try await child.snapshot(scope: .branch, requestedBase: "main")
        XCTAssertEqual(comparison.changes.map(\.path), ["notes.txt"])
        var input = RepositoryRequest(.diff); input.scope = .branch; input.base = "main"; input.path = "notes.txt"
        let patch = try await child.diff(input); XCTAssertTrue(patch.text.contains("+feature"))
        XCTAssertFalse(patch.text.contains("dirty parent"))
        do { _ = try await repository.createWorktree(branch: "--orphan", base: "main", storage: directory); XCTFail("Option-shaped branch accepted") } catch {}
    }
    func testTextEditorRejectsStaleEditsTraversalAndSymlinks() async throws {
        _ = try await repository()
        let folder = try SharedFolder(url: directory)
        let original = try folder.editableText("notes.txt")
        let saved = try folder.replaceText("notes.txt", text: "saved\n", revision: XCTUnwrap(original.revision))
        XCTAssertEqual(saved.text, "saved\n")
        XCTAssertThrowsError(try folder.replaceText("notes.txt", text: "stale", revision: XCTUnwrap(original.revision)))
        for path in ["../notes.txt", ".git/config", "/etc/passwd", "a/../../notes.txt"] { XCTAssertThrowsError(try folder.editableText(path)) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "private fixture".write(to: outside, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try folder.editableText("link"))
        XCTAssertThrowsError(try folder.replaceText("link", text: "escaped", revision: "anything"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private fixture")
        let repository = try await RepositoryService.open(directory)
        var input = RepositoryRequest(.diff); input.path = "link"
        let patch = try await repository.diff(input)
        XCTAssertFalse(patch.text.contains("private fixture"), "Diffing a symlink must not read outside the checkout")
    }
    func testRenameAndLiteralPathspecDoNotStageOtherFiles() async throws {
        let repository = try await repository()
        _ = try await git(["mv", "notes.txt", "renamed.txt"])
        let status = try await repository.snapshot(scope: .staged)
        XCTAssertEqual(status.changes.first?.previousPath, "notes.txt")
        try "literal".write(to: directory.appendingPathComponent(":(glob)*"), atomically: true, encoding: .utf8)
        try "other".write(to: directory.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await repository.stage(":(glob)*", undo: false)
        let staged = try await repository.snapshot(scope: .staged)
        XCTAssertTrue(staged.changes.contains { $0.path == ":(glob)*" }); XCTAssertFalse(staged.changes.contains { $0.path == "other.txt" })
        var input = RepositoryRequest(.diff); input.scope = .staged; input.path = "renamed.txt"; input.previousPath = "notes.txt"
        let patch = try await repository.diff(input)
        XCTAssertTrue(patch.text.contains("rename from notes.txt")); XCTAssertTrue(patch.text.contains("rename to renamed.txt"))
        try await repository.stage("renamed.txt", undo: true)
        let remaining = try await repository.snapshot(scope: .staged)
        XCTAssertEqual(remaining.changes.map(\.path), [":(glob)*"], "Unstaging a rename must restore both index paths and preserve other staged files")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("renamed.txt"), encoding: .utf8), "original\n")
    }
    func testCommandCancellationClosesTheChildAndBoundedOutputDrainsBothPipes() async throws {
        let output = try await DeveloperCommand.run("python3", ["-c", "import sys;sys.stdout.write('x'*5000000);sys.stderr.write('y'*20000)"], directory, nil)
        XCTAssertEqual(output.code, 0); XCTAssertTrue(output.truncated)
        let task = Task { try await DeveloperCommand.run("sleep", ["30"], directory, nil) }
        try await Task.sleep(nanoseconds: 100_000_000); let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled command completed") } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    func testInheritedGitDirectoryCannotRedirectProjectCommands() async throws {
        _ = try await repository()
        let previous = getenv("GIT_DIR").map { String(cString: $0) }
        setenv("GIT_DIR", "/not/the/conversation/repository", 1)
        defer { if let previous { setenv("GIT_DIR", previous, 1) } else { unsetenv("GIT_DIR") } }
        let service = try await RepositoryService.open(directory)
        XCTAssertEqual(service.root.path, directory.resolvingSymlinksInPath().path)
    }
    func testReviewedCommitRejectsStaleIndexAndPreservesUnstagedWork() async throws {
        let service = try await repository()
        try "staged\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try await service.stage("notes.txt", undo: false)
        let before = try await service.snapshot(scope: .staged)
        try "unrelated\n".write(to: directory.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await service.stage("other.txt", undo: false)
        do { try await service.commit(message: "Stale", revision: before.indexRevision); XCTFail("Stale staged files were committed") } catch {}
        try await service.stage("other.txt", undo: true)
        let reviewed = try await service.snapshot(scope: .staged)
        try "unstaged edit\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try await service.commit(message: "Literal `title` $(not-a-command)", revision: reviewed.indexRevision)
        let committed = try await git(["show", "HEAD:notes.txt"])
        XCTAssertEqual(committed, "staged\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8), "unstaged edit\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("other.txt"), encoding: .utf8), "unrelated\n")
    }
    func testPushUsesReviewedBranchAndNeverForces() async throws {
        let service = try await repository()
        let remote = directory.appendingPathComponent("remote.git")
        _ = try await git(["init", "--bare", remote.path]); _ = try await git(["remote", "add", "origin", remote.path])
        let reviewed = try await service.snapshot()
        do { try await service.push(remote: "origin", branch: "other", head: reviewed.head); XCTFail("Pushed a different branch") } catch {}
        try await service.push(remote: "origin", branch: reviewed.branch, head: reviewed.head)
        let remoteHead = try await git(["--git-dir", remote.path, "rev-parse", "refs/heads/main"])
        XCTAssertEqual(remoteHead.trimmingCharacters(in: .newlines), reviewed.head)
    }
}
