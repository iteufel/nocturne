import Foundation
import CryptoKit

public enum DeveloperProtocol {
    public static let capability = "developer-workspace-v1"
    public static let actionsCapability = "developer-actions-v1"
    public static let maximumTextBytes = 120_000
}

public struct ChatConfigChoice: Codable, Equatable, Identifiable {
    public let value: String
    public let name: String
    public let detail: String?
    public var id: String { value }
    public init(_ value: String, name: String, detail: String? = nil) { self.value = value; self.name = name; self.detail = detail }
}
public struct ChatConfigOption: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let category: String?
    public var value: String
    public let choices: [ChatConfigChoice]
    public let detail: String?
    public init(id: String, name: String, category: String? = nil, value: String, choices: [ChatConfigChoice], detail: String? = nil) {
        self.id = id; self.name = name; self.category = category; self.value = value; self.choices = choices; self.detail = detail
    }
}
public struct GitWorktree: Codable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let branch: String
    public let locked: Bool
    public let prunable: Bool
    public init(path: String, branch: String, locked: Bool = false, prunable: Bool = false) {
        self.path = path; self.branch = branch; self.locked = locked; self.prunable = prunable
    }
}
public enum GitDiffScope: String, Codable, CaseIterable { case agent, working, staged, branch }
public struct GitChange: Codable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let previousPath: String?
    public let indexStatus: String
    public let worktreeStatus: String
    public var staged: Bool { indexStatus != " " && indexStatus != "?" }
    public var unstaged: Bool { worktreeStatus != " " || indexStatus == "?" }
    public var conflicted: Bool { indexStatus == "U" || worktreeStatus == "U" || ["AA", "DD"].contains(indexStatus + worktreeStatus) }
    public init(path: String, previousPath: String? = nil, indexStatus: String, worktreeStatus: String) {
        self.path = path; self.previousPath = previousPath; self.indexStatus = indexStatus; self.worktreeStatus = worktreeStatus
    }
}
public struct ForgeRepository: Codable, Equatable {
    public enum Kind: String, Codable { case github, azureDevOps }
    public let kind: Kind
    public let host: String
    public let organization: String
    public let project: String?
    public let name: String
    public let webURL: String
    public init(kind: Kind, host: String, organization: String, project: String? = nil, name: String, webURL: String) {
        self.kind = kind; self.host = host; self.organization = organization; self.project = project; self.name = name; self.webURL = webURL
    }
}
public struct RepositorySnapshot: Codable, Equatable {
    public let root: String
    public let branch: String
    public let head: String?
    public let base: String?
    public let branches: [String]
    public var remotes: [String] = []
    public var indexRevision: String?
    public let worktrees: [GitWorktree]
    public let changes: [GitChange]
    public let forge: ForgeRepository?
    public let truncated: Bool
    public init(root: String, branch: String, head: String?, base: String?, branches: [String], worktrees: [GitWorktree], changes: [GitChange], forge: ForgeRepository?, truncated: Bool = false) {
        self.root = root; self.branch = branch; self.head = head; self.base = base; self.branches = branches
        self.worktrees = worktrees; self.changes = changes; self.forge = forge; self.truncated = truncated
    }
}
public struct RepositoryText: Codable, Equatable {
    public let path: String
    public let text: String
    public let revision: String?
    public let truncated: Bool
    public init(path: String, text: String, revision: String? = nil, truncated: Bool = false) {
        self.path = path; self.text = text; self.revision = revision; self.truncated = truncated
    }
}
public struct PullRequestInfo: Codable, Equatable, Identifiable {
    public var id: Int { number }
    public var revision: String { SHA256.hash(data: Data((String(number) + "\n" + title + "\n" + body).utf8)).map { String(format: "%02x", $0) }.joined() }
    public let number: Int
    public var title: String
    public var body: String
    public let author: String
    public let state: String
    public let draft: Bool
    public let source: String
    public let target: String
    public let url: String
    public let updatedAt: String?
    public let reviewers: [String]
    public let checks: [String]
    public var labels: [String]?
    public var additions: Int?
    public var deletions: Int?
    public var fileCount: Int?
    public var mergeable: Bool?
    public var authorID: String?
    public init(number: Int, title: String, body: String, author: String, state: String, draft: Bool, source: String, target: String, url: String, updatedAt: String? = nil, reviewers: [String] = [], checks: [String] = []) {
        self.number = number; self.title = title; self.body = body; self.author = author; self.state = state; self.draft = draft
        self.source = source; self.target = target; self.url = url; self.updatedAt = updatedAt; self.reviewers = reviewers; self.checks = checks
    }
}
public struct RepositoryRequest: Codable {
    public enum Action: String, Codable { case status, diff, readFile, saveFile, stage, unstage, createWorktree, pullRequests, pullRequest, editPullRequest, pullRequestFiles, pullRequestDiff, pullRequestActivity, commit, push, createPullRequest }
    public let action: Action
    public var path: String?
    public var previousPath: String?
    public var changeType: String?
    public var remote: String?
    public var scope: GitDiffScope = .working
    public var base: String?
    public var branch: String?
    public var text: String?
    public var revision: String?
    public var number: Int?
    public var title: String?
    public var allBranches = false
    public var includeClosed = false
    public var page = 1
    public init(_ action: Action) { self.action = action }
}
public struct RepositoryResponse: Codable {
    public var snapshot: RepositorySnapshot?
    public var content: RepositoryText?
    public var worktree: GitWorktree?
    public var pullRequests: [PullRequestInfo]?
    public var pullRequest: PullRequestInfo?
    public var changes: [GitChange]?
    public var hasMore = false
    public var activity: [PullRequestActivity]?
    public init() {}
}

public struct PullRequestActivity: Codable, Equatable, Identifiable {
    public let id: String
    public let author: String
    public let text: String
    public let createdAt: String?
    public let path: String?
    public init(id: String, author: String, text: String, createdAt: String? = nil, path: String? = nil) {
        self.id = id; self.author = author; self.text = text; self.createdAt = createdAt; self.path = path
    }
}
