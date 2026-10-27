import Foundation
import NocturneKit

/// Forge credentials stay inside the user's authenticated gh/az CLI on the Mac.
@MainActor
final class ForgeService {
    let repository: ForgeRepository
    let directory: URL
    let run: DeveloperCommand.Run
    private let headOwner: String?
    init(repository: ForgeRepository, directory: URL, run: @escaping DeveloperCommand.Run = DeveloperCommand.run, headOwner: String? = nil) {
        self.repository = repository; self.directory = directory; self.run = run; self.headOwner = headOwner
    }
    nonisolated static func parseRemote(_ raw: String) -> ForgeRepository? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://"), let colon = value.firstIndex(of: ":"), !value[..<colon].contains("/") {
            value = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...]
        }
        guard let url = URL(string: value), let host = url.host?.lowercased(), ["https", "ssh", "http"].contains(url.scheme ?? "") else { return nil }
        let parts = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        func valid(_ part: String) -> Bool { !part.isEmpty && part != "." && part != ".." && !part.contains("/") && !part.contains("\\") && !part.utf8.contains(0) }
        guard parts.allSatisfy(valid) else { return nil }
        func web(_ host: String, _ path: [String]) -> String {
            var c = URLComponents(); c.scheme = "https"; c.host = host; c.port = url.scheme == "https" ? url.port : nil
            c.path = "/" + path.joined(separator: "/"); return c.url?.absoluteString ?? ""
        }
        if ["ssh.dev.azure.com", "vs-ssh.visualstudio.com"].contains(host), parts.count == 4, parts[0] == "v3" {
            return ForgeRepository(kind: .azureDevOps, host: "dev.azure.com", organization: parts[1], project: parts[2], name: parts[3], webURL: web("dev.azure.com", [parts[1], parts[2], "_git", parts[3]]))
        }
        if let marker = parts.firstIndex(of: "_git"), marker >= 1, parts.count == marker + 2 {
            let project = parts[marker - 1], name = parts[marker + 1]
            if host == "dev.azure.com", marker == 2 {
                return ForgeRepository(kind: .azureDevOps, host: host, organization: parts[0], project: project, name: name, webURL: web(host, parts))
            }
            if host.hasSuffix(".visualstudio.com") {
                return ForgeRepository(kind: .azureDevOps, host: host, organization: String(host.dropLast(".visualstudio.com".count)), project: project, name: name, webURL: web(host, parts))
            }
            // Azure DevOps Server keeps its collection in the organization URL.
            if marker >= 2 {
                return ForgeRepository(kind: .azureDevOps, host: host, organization: parts.prefix(marker - 1).joined(separator: "/"), project: project, name: name, webURL: web(host, parts))
            }
        }
        guard parts.count == 2, !["gitlab.com", "bitbucket.org", "codeberg.org"].contains(host) else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard !name.isEmpty else { return nil }
        return ForgeRepository(kind: .github, host: host, organization: parts[0], name: name, webURL: web(host, [parts[0], name]))
    }
    private var ghPath: String { "repos/\(encoded(repository.organization))/\(encoded(repository.name))" }
    private var organizationURL: String {
        if repository.host == "dev.azure.com" { return "https://dev.azure.com/" + encoded(repository.organization) }
        if repository.host.hasSuffix(".visualstudio.com") { return "https://" + repository.host }
        return "https://" + repository.host + "/" + repository.organization.split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
    }
    private func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "" }
    private func command(_ executable: String, _ arguments: [String], input: Data? = nil) async throws -> DeveloperCommandResult {
        let result = try await run(executable, arguments, directory, input)
        guard result.code == 0 else {
            let login = executable == "gh" ? "gh auth login --hostname \(repository.host)" : "az login or az devops login --organization \(organizationURL)"
            throw NocturneError.remote("\(executable == "gh" ? "GitHub" : "Azure DevOps") request failed. Check access and sign in on your Mac with \(login). \(result.error)")
        }
        return result
    }
    private func json(_ result: DeveloperCommandResult) throws -> Any {
        guard !result.truncated else { throw NocturneError.remote("The forge returned too much data. Choose a smaller page or file.") }
        return try JSONSerialization.jsonObject(with: result.data)
    }
    private func gh(_ path: String, fields: [String] = [], method: String = "GET", body: [String: Any]? = nil, diff: Bool = false) async throws -> DeveloperCommandResult {
        var args = ["api", "--hostname", repository.host, "--method", method, path]
        for field in fields { args += ["--raw-field", field] }
        if diff { args += ["--header", "Accept: application/vnd.github.diff"] }
        if body != nil { args += ["--input", "-"] }
        return try await command("gh", args, input: try body.map { try JSONSerialization.data(withJSONObject: $0) })
    }
    private func azure(_ resource: String, number: Int? = nil, extraRoute: [String] = [], query: [String] = [], body: [String: Any]? = nil, area: String = "git") async throws -> Any {
        var args = ["devops", "invoke", "--organization", organizationURL, "--area", area, "--resource", resource,
            "--api-version", "7.1", "--route-parameters", "project=\(repository.project ?? "")"]
        if area == "git" { args.append("repositoryId=\(repository.name)") }
        if let number { args.append("pullRequestId=\(number)") }
        args += extraRoute
        if !query.isEmpty { args += ["--query-parameters"] + query }
        let temporary = directoryForBody()
        defer { if body != nil { try? FileManager.default.removeItem(at: temporary) } }
        if let body {
            let data = try JSONSerialization.data(withJSONObject: body)
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            args += ["--http-method", "PATCH", "--in-file", temporary.path]
        }
        args += ["--only-show-errors", "--output", "json"]
        return try json(await command("az", args))
    }
    private func directoryForBody() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-pr-" + UUID().uuidString + ".json") }
    private func values(_ value: Any) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        return (value as? [String: Any])?["value"] as? [[String: Any]] ?? []
    }
    func list(branch: String?, page: Int, includeClosed: Bool = false) async throws -> ([PullRequestInfo], Bool) {
        guard (1...100).contains(page) else { throw NocturneError.invalidFrame }
        if repository.kind == .github {
            var fields = ["state=\(includeClosed ? "all" : "open")", "per_page=30", "page=\(page)", "sort=updated", "direction=desc"]
            if let branch { fields.append("head=\(headOwner ?? repository.organization):\(branch)") }
            let array = values(try json(await gh(ghPath + "/pulls", fields: fields)))
            return (try array.map { var summary = try decode($0); summary.body = ""; return summary }, array.count == 30)
        }
        var query = ["searchCriteria.status=\(includeClosed ? "all" : "active")", "$top=30", "$skip=\((page - 1) * 30)"]
        if let branch { query.append("searchCriteria.sourceRefName=refs/heads/" + branch) }
        let array = values(try await azure("pullRequests", query: query))
        return (try array.map { var summary = try decode($0); summary.body = ""; return summary }, array.count == 30)
    }
    func detail(_ number: Int) async throws -> PullRequestInfo {
        guard number > 0 else { throw NocturneError.invalidFrame }
        let raw = try await rawDetail(number)
        var checks: [String] = []
        var reviewers: [String]?
        if repository.kind == .github, let sha = (raw["head"] as? [String: Any])?["sha"] as? String {
            do {
                let response = try await gh(ghPath + "/commits/" + encoded(sha) + "/check-runs", fields: ["per_page=50"])
                guard let body = try json(response) as? [String: Any] else { throw NocturneError.invalidFrame }
                checks = (body["check_runs"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "Check") + " · " + ($0["conclusion"] as? String ?? $0["status"] as? String ?? "pending") }
            } catch { checks = ["Checks unavailable: " + DeveloperCommand.sanitize(error.localizedDescription)] }
            do {
                let response = try await gh(ghPath + "/commits/" + encoded(sha) + "/status")
                let body = try json(response) as? [String: Any] ?? [:]
                checks += (body["statuses"] as? [[String: Any]] ?? []).map { ($0["context"] as? String ?? "Status") + " · " + ($0["state"] as? String ?? "pending") }
            } catch { checks.append("Commit statuses unavailable: " + DeveloperCommand.sanitize(error.localizedDescription)) }
            do {
                let rows = values(try json(await gh(ghPath + "/pulls/\(number)/reviews", fields: ["per_page=100"])))
                var states: [String: String] = [:]
                for row in rows {
                    if let name = (row["user"] as? [String: Any])?["login"] as? String {
                        states[name] = name + " · " + (row["state"] as? String ?? "Pending").lowercased().replacingOccurrences(of: "_", with: " ").capitalized
                    }
                }
                for row in raw["requested_reviewers"] as? [[String: Any]] ?? [] {
                    if let name = row["login"] as? String { states[name] = name + " · Requested" }
                }
                reviewers = states.sorted(by: { $0.key < $1.key }).map(\.value)
            } catch { reviewers = ["Review history unavailable: " + DeveloperCommand.sanitize(error.localizedDescription)] }
        } else if let projectID = ((raw["repository"] as? [String: Any])?["project"] as? [String: Any])?["id"] as? String {
            do {
                let policies = try await azure("evaluations", query: ["artifactId=vstfs:///CodeReview/CodeReviewId/\(projectID)/\(number)"], area: "policy")
                checks = values(policies).map { value in
                    let config = value["configuration"] as? [String: Any] ?? [:]
                    return ((config["type"] as? [String: Any])?["displayName"] as? String ?? "Policy") + " · " + (value["status"] as? String ?? "pending")
                }
            } catch { checks = ["Policies unavailable: " + DeveloperCommand.sanitize(error.localizedDescription)] }
        }
        return try decode(raw, checks: checks, reviewers: reviewers)
    }
    private func rawDetail(_ number: Int) async throws -> [String: Any] {
        let object = repository.kind == .github ? try json(await gh(ghPath + "/pulls/\(number)")) : try await azure("pullRequests", number: number)
        guard let value = object as? [String: Any] else { throw NocturneError.invalidFrame }; return value
    }
    func edit(_ number: Int, title: String, body: String, expectedRevision: String?) async throws -> PullRequestInfo {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 400,
              body.utf8.count <= 60_000, number > 0 else { throw NocturneError.invalidFrame }
        let current = try await rawDetail(number), before = try decode(current)
        guard expectedRevision == Self.revision(before) else { throw NocturneError.remote("This pull request changed since you opened it. Refresh before saving your edit.") }
        if repository.kind == .github { _ = try await gh(ghPath + "/pulls/\(number)", method: "PATCH", body: ["title": title, "body": body]) }
        else { _ = try await azure("pullRequests", number: number, body: ["title": title, "description": body]) }
        return try await detail(number)
    }
    static func revision(_ request: PullRequestInfo) -> String { request.revision }
    private func decode(_ raw: [String: Any], checks: [String] = [], reviewers: [String]? = nil) throws -> PullRequestInfo {
        if repository.kind == .github {
            guard let number = raw["number"] as? Int, let title = raw["title"] as? String else { throw NocturneError.invalidFrame }
            return PullRequestInfo(number: number, title: title, body: raw["body"] as? String ?? "", author: (raw["user"] as? [String: Any])?["login"] as? String ?? "",
                state: raw["merged_at"] is String ? "merged" : raw["state"] as? String ?? "open", draft: raw["draft"] as? Bool ?? false,
                source: (raw["head"] as? [String: Any])?["ref"] as? String ?? "", target: (raw["base"] as? [String: Any])?["ref"] as? String ?? "",
                url: raw["html_url"] as? String ?? repository.webURL + "/pull/\(number)", updatedAt: raw["updated_at"] as? String,
                reviewers: reviewers ?? (raw["requested_reviewers"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }, checks: checks)
        }
        guard let number = raw["pullRequestId"] as? Int, let title = raw["title"] as? String else { throw NocturneError.invalidFrame }
        return PullRequestInfo(number: number, title: title, body: raw["description"] as? String ?? "", author: (raw["createdBy"] as? [String: Any])?["displayName"] as? String ?? "",
            state: raw["status"] as? String ?? "active", draft: raw["isDraft"] as? Bool ?? false,
            source: (raw["sourceRefName"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: ""), target: (raw["targetRefName"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: ""),
            url: repository.webURL + "/pullrequest/\(number)", updatedAt: raw["closedDate"] as? String ?? raw["creationDate"] as? String,
            reviewers: (raw["reviewers"] as? [[String: Any]] ?? []).map { ($0["displayName"] as? String ?? "Reviewer") + " · " + ([10: "Approved", 5: "Approved with suggestions", 0: "Waiting", -5: "Waiting for author", -10: "Rejected"][$0["vote"] as? Int ?? 0] ?? "Pending") }, checks: checks)
    }
    func files(_ number: Int, page: Int) async throws -> ([GitChange], Bool) {
        guard number > 0, (1...100).contains(page) else { throw NocturneError.invalidFrame }
        if repository.kind == .github {
            let rows = values(try json(await gh(ghPath + "/pulls/\(number)/files", fields: ["per_page=100", "page=\(page)"])))
            let changes = rows.compactMap { row -> GitChange? in
                guard let path = row["filename"] as? String else { return nil }
                let code = ["added": "A", "removed": "D", "renamed": "R" ][row["status"] as? String ?? ""] ?? "M"
                return GitChange(path: path, previousPath: row["previous_filename"] as? String, indexStatus: code, worktreeStatus: " ")
            }
            return (changes, rows.count == 100)
        }
        let iteration = try await latestIteration(number)
        guard let id = iteration["id"] as? Int else { throw NocturneError.invalidFrame }
        let raw = try await azure("pullRequestIterationChanges", number: number, extraRoute: ["iterationId=\(id)"], query: ["$top=100", "$skip=\((page - 1) * 100)", "$compareTo=0"]) as? [String: Any] ?? [:]
        let rows = raw["changeEntries"] as? [[String: Any]] ?? []
        return (rows.compactMap { row in
            guard let path = (row["item"] as? [String: Any])?["path"] as? String else { return nil }
            let kind = row["changeType"] as? String ?? ((row["changeType"] as? Int).map { $0 == 1 ? "add" : $0 == 16 ? "delete" : $0 == 8 ? "rename" : "edit" } ?? "edit")
            return GitChange(path: String(path.drop(while: { $0 == "/" })), previousPath: (row["originalPath"] as? String).map { String($0.drop(while: { $0 == "/" })) }, indexStatus: kind, worktreeStatus: " ")
        }, (raw["nextSkip"] as? Int ?? 0) > 0)
    }
    private func latestIteration(_ number: Int) async throws -> [String: Any] {
        let rows = values(try await azure("pullRequestIterations", number: number))
        guard let latest = rows.max(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }) else { throw NocturneError.remote("This PR has no diff iteration yet.") }
        return latest
    }
    func diff(_ number: Int, path: String, previousPath: String?, changeType: String? = nil) async throws -> RepositoryText {
        try RepositoryService.validatePath(path)
        if let previousPath { try RepositoryService.validatePath(previousPath) }
        if repository.kind == .github {
            // GitHub's file patch can be absent or truncated; never pretend it is a full diff.
            for page in 1...30 {
                let rows = values(try json(await gh(ghPath + "/pulls/\(number)/files", fields: ["per_page=100", "page=\(page)"])))
                if let row = rows.first(where: { $0["filename"] as? String == path }) {
                    let patch = row["patch"] as? String ?? "Binary file, or GitHub did not provide a patch. Open this PR in the browser for the complete file."
                    let result = DeveloperCommandResult(data: Data(patch.utf8), error: "", code: 0, truncated: true)
                    return RepositoryService.text(path, result)
                }
                if rows.count < 100 { break }
            }
            throw NocturneError.remote("This file is no longer in the PR. Refresh its changes.")
        }
        let iteration = try await latestIteration(number)
        guard let head = (iteration["sourceRefCommit"] as? [String: Any])?["commitId"] as? String,
              let base = (iteration["commonRefCommit"] as? [String: Any])?["commitId"] as? String else { throw NocturneError.remote("Azure DevOps did not supply the PR comparison commits.") }
        let before = try await azureContent(path: previousPath ?? path, commit: base, allowMissing: changeType?.lowercased().contains("add") == true)
        let after = try await azureContent(path: path, commit: head, allowMissing: changeType?.lowercased().contains("delete") == true)
        guard before != nil, after != nil else { return RepositoryText(path: path, text: "Binary file. Open the pull request in Azure DevOps to review it.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let left = temporary.appendingPathComponent("before"), right = temporary.appendingPathComponent("after")
        try before!.write(to: left, atomically: true, encoding: .utf8); try after!.write(to: right, atomically: true, encoding: .utf8)
        let result = try await run("diff", ["-u", "--label", "a/" + (previousPath ?? path), "--label", "b/" + path, "--", left.path, right.path], directory, nil)
        guard result.code == 0 || result.code == 1 else { throw NocturneError.remote("Could not compare the PR file.") }
        return RepositoryService.text(path, result)
    }
    private func azureContent(path: String, commit: String, allowMissing: Bool) async throws -> String? {
        do {
            let result = try await azure("items", query: ["path=/" + path, "versionDescriptor.versionType=commit", "versionDescriptor.version=" + commit, "includeContent=true", "includeContentMetadata=true", "$format=json"]) as? [String: Any] ?? [:]
            if (result["contentMetadata"] as? [String: Any])?["isBinary"] as? Bool == true { return nil }
            guard let content = result["content"] as? String, content.utf8.count <= DeveloperProtocol.maximumTextBytes else { throw NocturneError.remote("This PR file is too large for the editor. Open it in Azure DevOps.") }
            return content
        } catch {
            if allowMissing, error.localizedDescription.contains("TF401174") || error.localizedDescription.contains("404") { return "" }
            throw error
        }
    }
}
