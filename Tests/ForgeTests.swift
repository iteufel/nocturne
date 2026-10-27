import XCTest
import NocturneKit
@testable import NocturneHostKit

@MainActor
final class ForgeTests: XCTestCase {
    func testRemoteParsingHandlesAzureSSHLegacyAndGitHubWithoutCredentials() throws {
        for remote in ["git@ssh.dev.azure.com:v3/acme/Project%20One/repo", "https://user:private@dev.azure.com/acme/Project%20One/_git/repo", "ssh://git@ssh.dev.azure.com/v3/acme/Project%20One/repo"] {
            let parsed = try XCTUnwrap(ForgeService.parseRemote(remote))
            XCTAssertEqual(parsed.kind, .azureDevOps); XCTAssertEqual(parsed.organization, "acme"); XCTAssertEqual(parsed.project, "Project One")
            XCTAssertFalse(parsed.webURL.contains("private")); XCTAssertFalse(parsed.webURL.contains("user@"))
        }
        let legacy = try XCTUnwrap(ForgeService.parseRemote("https://acme.visualstudio.com/DefaultCollection/project/_git/repo"))
        XCTAssertEqual(legacy.project, "project"); XCTAssertEqual(legacy.organization, "acme")
        let enterprise = try XCTUnwrap(ForgeService.parseRemote("ssh://git@github.example.com:2222/owner/repo.git"))
        XCTAssertEqual(enterprise.webURL, "https://github.example.com/owner/repo")
        XCTAssertEqual(ForgeService.parseRemote("git@github.com:owner/repo.git")?.name, "repo")
        XCTAssertNil(ForgeService.parseRemote("file:///tmp/repo")); XCTAssertNil(ForgeService.parseRemote("https://github.com/owner/%2e%2e"))
    }
    func testGitHubPRReadsAndStructuredEditsPreserveMarkdownAndRejectStaleWrites() async throws {
        let fixture = ForgeFixture(.github)
        let provider = ForgeService(repository: fixture.repository, directory: FileManager.default.temporaryDirectory, run: fixture.run)
        let rows = try await provider.list(branch: "feature/a", page: 1)
        XCTAssertEqual(rows.0.first?.number, 7)
        let initial = try await provider.detail(7)
        XCTAssertEqual(initial.checks, ["unit · success"])
        let title = "--literal `title` $(do-not-run)", body = "First line\n\n* Markdown\nLiteral \\n and `code`"
        let updated = try await provider.edit(7, title: title, body: body, expectedRevision: initial.revision)
        XCTAssertEqual(updated.title, title); XCTAssertEqual(updated.body, body)
        let mutation = try XCTUnwrap(fixture.calls.last { $0.arguments.contains("PATCH") })
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(mutation.input)) as? [String: String])
        XCTAssertEqual(payload, ["title": title, "body": body]); XCTAssertFalse(mutation.arguments.contains(body))
        let mutations = fixture.calls.filter { $0.arguments.contains("PATCH") }.count
        do { _ = try await provider.edit(7, title: "stale", body: "old", expectedRevision: initial.revision); XCTFail("Stale PR edit accepted") } catch {}
        XCTAssertEqual(fixture.calls.filter { $0.arguments.contains("PATCH") }.count, mutations)
    }
    func testAzurePRReadsFilesAndEditsUseExplicitRoutesAndJSONBodyFile() async throws {
        let fixture = ForgeFixture(.azureDevOps)
        let provider = ForgeService(repository: fixture.repository, directory: FileManager.default.temporaryDirectory, run: fixture.run)
        let rows = try await provider.list(branch: "feature/a", page: 2)
        XCTAssertEqual(rows.0.first?.title, "Fixture PR")
        let current = try await provider.detail(7)
        XCTAssertEqual(current.checks, ["Build · approved"])
        let files = try await provider.files(7, page: 1); XCTAssertEqual(files.0.first?.path, "notes.txt")
        let diff = try await provider.diff(7, path: "notes.txt", previousPath: nil)
        XCTAssertTrue(diff.text.contains("-before")); XCTAssertTrue(diff.text.contains("+after"))
        let updated = try await provider.edit(7, title: "--literal title", body: "one\n\n**two**", expectedRevision: current.revision)
        XCTAssertEqual(updated.body, "one\n\n**two**")
        XCTAssertTrue(fixture.calls.allSatisfy { $0.executable == "diff" || ($0.arguments.contains("https://dev.azure.com/acme") && $0.arguments.contains("project=Project One")) })
        XCTAssertTrue(fixture.bodyFileWasPrivate); XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bodyFilePath ?? ""))
        let list = try XCTUnwrap(fixture.calls.first)
        XCTAssertTrue(list.arguments.contains("$skip=30")); XCTAssertTrue(list.arguments.contains("searchCriteria.sourceRefName=refs/heads/feature/a"))
    }
    func testForgeFailuresAreVisibleAndDoNotRetryOnAnotherProvider() async throws {
        let fixture = ForgeFixture(.azureDevOps); fixture.fail = true
        let provider = ForgeService(repository: fixture.repository, directory: FileManager.default.temporaryDirectory, run: fixture.run)
        do { _ = try await provider.detail(7); XCTFail("Authentication error hidden") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Azure DevOps")) }
        XCTAssertEqual(fixture.calls.count, 1); XCTAssertEqual(fixture.calls.first?.executable, "az")
        let clean = DeveloperCommand.sanitize("Bearer eyJfixture.foo.bar github_pat_private https://user:password@example.com")
        XCTAssertFalse(clean.contains("eyJfixture")); XCTAssertFalse(clean.contains("github_pat_private")); XCTAssertFalse(clean.contains("password"))
    }
    func testGitHubUpstreamListingUsesTheForkHeadOwner() async throws {
        let fixture = ForgeFixture(.github)
        let provider = ForgeService(repository: fixture.repository, directory: FileManager.default.temporaryDirectory, run: fixture.run, headOwner: "fork-owner")
        _ = try await provider.list(branch: "feature/a", page: 1)
        XCTAssertTrue(fixture.calls.first?.arguments.contains("head=fork-owner:feature/a") == true)
    }
    func testCreationAndActivityUseRealForgeRoutesAndStructuredPayloads() async throws {
        for kind in [ForgeRepository.Kind.github, .azureDevOps] {
            let fixture = ForgeFixture(kind)
            let provider = ForgeService(repository: fixture.repository, directory: FileManager.default.temporaryDirectory, run: fixture.run, headOwner: "fork")
            let created = try await provider.create(title: "Literal `title` $(never-run)", body: "One\n\n**Two**", source: "feature/a", target: "main")
            XCTAssertEqual(created.number, 7)
            XCTAssertEqual(fixture.bodyJSON?[kind == .github ? "head" : "sourceRefName"], kind == .github ? "fork:feature/a" : "refs/heads/feature/a")
            XCTAssertEqual(fixture.bodyJSON?[kind == .github ? "base" : "targetRefName"], kind == .github ? "main" : "refs/heads/main")
            XCTAssertTrue(fixture.calls.contains { $0.arguments.contains("POST") })
            let activity = try await provider.activity(7)
            XCTAssertTrue(activity.contains { $0.text.contains("Please test cancellation") })
            XCTAssertEqual(Set(activity.map(\.id)).count, activity.count)
            if kind == .azureDevOps { XCTAssertTrue(fixture.bodyFileWasPrivate); XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bodyFilePath ?? "")) }
        }
    }
    func testInstalledGitHubAndAzureDevOpsReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["NOCTURNE_TEST_FORGES"] == "1" else { throw XCTSkip("Opt-in read-only forge integration with existing Mac logins.") }
        let paths = [ProcessInfo.processInfo.environment["NOCTURNE_TEST_GITHUB_REPO"], ProcessInfo.processInfo.environment["NOCTURNE_TEST_AZURE_REPO"]]
        guard paths.allSatisfy({ $0 != nil }) else { throw XCTSkip("Set both forge checkout paths for the read-only live checks.") }
        for path in paths.compactMap({ $0 }) {
            let service = try await RepositoryService.open(URL(fileURLWithPath: path))
            let state = try await service.snapshot()
            let provider = ForgeService(repository: try XCTUnwrap(state.forge), directory: service.root)
            let rows = try await provider.list(branch: nil, page: 1, includeClosed: true)
            let first = try XCTUnwrap(rows.0.first, "Use a repository with at least one PR for the live check")
            let detail = try await provider.detail(first.number); XCTAssertEqual(detail.number, first.number)
            let files = try await provider.files(first.number, page: 1)
            let activity = try await provider.activity(first.number)
            XCTAssertEqual(Set(activity.map(\.id)).count, activity.count)
            if let file = files.0.first { let patch = try await provider.diff(first.number, path: file.path, previousPath: file.previousPath, changeType: file.indexStatus); XCTAssertEqual(patch.path, file.path) }
            print("Verified \(state.forge?.kind.rawValue ?? "forge"): PR listing, detail, changed files and diff")
        }
    }
}

private final class ForgeFixture: @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let input: Data? }
    let repository: ForgeRepository
    var calls: [Call] = []
    var title = "Fixture PR", body = "Initial body"
    var fail = false, bodyFileWasPrivate = false
    var bodyFilePath: String?
    var bodyJSON: [String: String]?
    init(_ kind: ForgeRepository.Kind) {
        repository = ForgeRepository(kind: kind, host: kind == .github ? "github.com" : "dev.azure.com", organization: "acme", project: kind == .github ? nil : "Project One", name: "repo", webURL: kind == .github ? "https://github.com/acme/repo" : "https://dev.azure.com/acme/Project%20One/_git/repo")
    }
    var run: DeveloperCommand.Run { { [self] executable, args, directory, input in
        try await respond(executable, args: args, directory: directory, input: input)
    } }
    private func respond(_ executable: String, args: [String], directory: URL, input: Data?) async throws -> DeveloperCommandResult {
        calls.append(Call(executable: executable, arguments: args, input: input))
        if executable == "diff" { return try await DeveloperCommand.run(executable, args, directory, input) }
        if fail { return DeveloperCommandResult(data: Data(), error: "HTTP 401 unauthorized", code: 1, truncated: false) }
        var result: Any
        if repository.kind == .github {
            if args.contains("PATCH") || args.contains("POST"), let input, let values = try JSONSerialization.jsonObject(with: input) as? [String: String] { bodyJSON = values; title = values["title"]!; body = values["body"]! }
            let path = args.first { $0.hasPrefix("repos/") } ?? ""
            if path.hasSuffix("check-runs") { result = ["check_runs": [["name": "unit", "conclusion": "success"]]] }
            else if path.hasSuffix("/files") { result = [["filename": "notes.txt", "status": "modified", "patch": "@@ -1 +1 @@\n-before\n+after"]] }
            else if path.hasSuffix("/comments") { result = [["id": 1, "user": ["login": "reviewer"], "body": "Please test cancellation", "created_at": "2026-10-27T19:00:00Z"]] }
            else if path.hasSuffix("/reviews") { result = [["id": 2, "user": ["login": "reviewer"], "state": "APPROVED", "body": "Looks good", "submitted_at": "2026-10-27T19:02:00Z"]] }
            else if path.hasSuffix("/pulls") { result = args.contains("POST") ? github : [github] }
            else { result = github }
        } else {
            let resource = args[args.firstIndex(of: "--resource")! + 1]
            if let index = args.firstIndex(of: "--in-file") {
                let file = args[index + 1]; bodyFilePath = file
                let attributes = try FileManager.default.attributesOfItem(atPath: file)
                bodyFileWasPrivate = (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
                let values = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: String]
                bodyJSON = values
                title = values["title"]!; body = values["description"]!
            }
            switch resource {
            case "evaluations": result = ["value": [["configuration": ["type": ["displayName": "Build"]], "status": "approved"]]]
            case "pullRequestIterations": result = ["value": [["id": 2, "commonRefCommit": ["commitId": "base"], "sourceRefCommit": ["commitId": "head"]]]]
            case "pullRequestIterationChanges": result = ["changeEntries": [["item": ["path": "/notes.txt"], "changeType": "edit"]], "nextSkip": 0]
            case "items": result = ["content": args.contains("versionDescriptor.version=base") ? "before\n" : "after\n", "contentMetadata": ["isBinary": false]]
            case "pullRequestThreads": result = ["value": [["id": 1, "threadContext": ["filePath": "/notes.txt"], "comments": [["id": 2, "author": ["displayName": "Reviewer"], "content": "Please test cancellation", "publishedDate": "2026-10-27T19:00:00Z"]]]]]
            default:
                if args.contains("pullRequestId=7") || args.contains("POST") { result = azure }
                else { result = ["value": [azure]] }
            }
        }
        return DeveloperCommandResult(data: try JSONSerialization.data(withJSONObject: result), error: "", code: 0, truncated: false)
    }
    private var github: [String: Any] { ["number": 7, "title": title, "body": body, "user": ["login": "tester"], "state": "open", "head": ["ref": "feature/a", "sha": "abcdef"], "base": ["ref": "main"], "html_url": "https://github.com/acme/repo/pull/7"] }
    private var azure: [String: Any] { ["pullRequestId": 7, "title": title, "description": body, "status": "active", "sourceRefName": "refs/heads/feature/a", "targetRefName": "refs/heads/main", "repository": ["name": "repo", "project": ["id": "project-id"]]] }
}
