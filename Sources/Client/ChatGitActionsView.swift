import SwiftUI
import NocturneKit

struct ChatGitActionsView: View {
    @ObservedObject var project: DeveloperWorkspaceModel
    var created: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var preview: RepositorySnapshot?
    @State private var message = ""
    @State private var title = ""
    @State private var description = ""
    @State private var base = ""
    @State private var status: String?
    private var locked: Bool { project.busy || project.chat.responding || project.chat.loading || project.chat.voiceEngaged }
    var body: some View {
        NavigationStack {
            Form {
                if let error = project.error { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
                if let status { Section { Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(ChatStyle.green) } }
                Section {
                    Label(project.snapshot?.branch ?? L("Checkout"), systemImage: "arrow.triangle.branch").font(.system(.subheadline, design: .monospaced))
                    Text(project.snapshot?.root ?? "").font(.caption).foregroundStyle(ChatStyle.secondary)
                    Picker(L("Remote"), selection: $project.remote) { ForEach(project.snapshot?.remotes ?? [], id: \.self) { Text($0).tag($0) } }
                }
                Section(L("1 · Commit staged files")) {
                    TextField(L("Commit message"), text: $message, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("gitCommitMessage")
                    ForEach(preview?.changes ?? []) { file in Label(file.path, systemImage: "doc.text").font(.system(.caption, design: .monospaced)) }
                    if preview?.changes.isEmpty == true { Text(L("Stage files in Review changes first.")).font(.caption).foregroundStyle(ChatStyle.secondary) }
                    Button(L("Refresh staged files"), systemImage: "arrow.clockwise") { Task { await refreshPreview() } }
                    Button(L("Commit staged files")) {
                        Task { if await project.commit(message, revision: preview?.indexRevision) { status = L("Commit created"); message = ""; await refreshPreview() } }
                    }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preview?.changes.isEmpty != false).accessibilityIdentifier("commitStagedFiles")
                }
                Section(L("2 · Push branch")) {
                    Text(L("Push the current branch to the selected remote.")).font(.caption).foregroundStyle(ChatStyle.secondary)
                    Button(L("Push branch"), systemImage: "arrow.up") { Task { if await project.push() { status = L("Branch pushed to %@", project.remote) } } }
                        .disabled(project.snapshot?.head == nil || project.remote.isEmpty || project.snapshot?.branch == "Detached HEAD").accessibilityIdentifier("pushChatBranch")
                }
                Section(L("3 · Create pull request")) {
                    TextField(L("Pull request title"), text: $title).accessibilityIdentifier("newPullRequestTitle")
                    TextEditor(text: $description).frame(minHeight: 140).accessibilityIdentifier("newPullRequestDescription")
                    Picker(L("Target branch"), selection: $base) { ForEach(project.snapshot?.branches ?? [], id: \.self) { Text($0).tag($0) } }
                    Button(L("Create pull request"), systemImage: "arrow.triangle.pull") {
                        Task { if await project.createPullRequest(title: title, body: description, base: base) { status = L("Pull request created"); created() } }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.isEmpty || project.snapshot?.forge == nil).accessibilityIdentifier("createChatPullRequest")
                    if let request = project.selectedPR, let url = URL(string: request.url), url.scheme == "https" { Link(L("Open PR #%@", "\(request.number)"), destination: url) }
                }
                if locked { Section { ProgressView(L("Working…")) } }
            }.disabled(locked)
                .navigationTitle(L("Commit, push & PR")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() }.disabled(project.busy) } }
                .task { await project.refresh(); base = project.snapshot?.base ?? project.snapshot?.branches.first ?? ""; await refreshPreview() }
                .onChange(of: project.remote) { _, _ in Task { await project.refresh() } }
        }
    }
    private func refreshPreview() async { preview = await project.previewCommit() }
}
