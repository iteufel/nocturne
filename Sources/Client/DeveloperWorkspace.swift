import SwiftUI
import NocturneKit

struct DeveloperContextBar: View {
    @ObservedObject var project: DeveloperWorkspaceModel
    @ObservedObject var chat: ChatWorkspaceModel
    @Binding var showingWorktrees: Bool
    var body: some View {
        HStack(spacing: 12) {
            Button { showingWorktrees = true } label: {
                Label(project.snapshot?.branch ?? L("Project checkout"), systemImage: "arrow.triangle.branch")
                    .lineLimit(1).font(.system(.caption, design: .monospaced))
            }.accessibilityIdentifier("chatWorktrees")
                .disabled(project.busy || chat.loading || chat.responding || chat.voiceEngaged || chat.configuring)
            Spacer(minLength: 0)
            if let snapshot = project.snapshot { Text(URL(fileURLWithPath: snapshot.root).lastPathComponent).font(.caption).foregroundStyle(MoonStyle.secondary).lineLimit(1) }
            Button(L("Refresh project"), systemImage: "arrow.clockwise") { Task { await project.refresh() } }
                .labelStyle(.iconOnly).disabled(project.busy || chat.loading).accessibilityIdentifier("refreshProject")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ChatConfigurationBar: View {
    @ObservedObject var model: ChatWorkspaceModel
    var inline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(model.options) { option in
                        Menu {
                            Picker(NocturneLocalization.message(option.name), selection: Binding(get: { option.value }, set: { value in Task { await model.configure(option, value: value) } })) {
                                ForEach(option.choices) { choice in Text(choice.name).tag(choice.value) }
                            }
                        } label: {
                            Label(option.choices.first(where: { $0.value == option.value })?.name ?? option.name,
                                systemImage: option.category == "thought_level" ? "brain" : "cpu")
                                .font(.caption).lineLimit(1)
                                .foregroundStyle(option.category == "thought_level" ? ChatStyle.secondary : Color.primary)
                        }.accessibilityLabel(NocturneLocalization.message(option.name)).accessibilityIdentifier("chatOption-" + option.id)
                    }
                    if model.configuring { ProgressView().controlSize(.mini) }
                }.disabled(model.loading || model.responding || model.voiceEngaged || model.configuring)
            }
            if let error = model.optionsError {
                HStack(alignment: .top) {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                    Button(L("Retry settings")) { Task { await model.refreshOptions() } }.font(.caption2).disabled(model.loading || model.responding)
                }
            }
        }.padding(.horizontal, inline ? 0 : 16).padding(.top, inline || (model.options.isEmpty && model.optionsError == nil) ? 0 : 10)
    }
}

struct DeveloperProjectPane: View {
    enum Tab: String, CaseIterable { case conversation = "Conversation", changes = "Changes", pullRequests = "Pull requests" }
    @ObservedObject var model: DeveloperWorkspaceModel
    let tab: Tab
    @State private var selectedFile: GitChange?
    @State private var showingPR = false
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            if model.busy { ProgressView().controlSize(.small).padding(8) }
            if let error = model.error { DeveloperErrorView(message: error) { model.error = nil } }
            if tab == .changes { changes }
            else { pullRequests }
        }
        .sheet(item: $selectedFile) { file in DeveloperFileView(model: model, file: file, pullRequest: nil) }
        .sheet(isPresented: $showingPR) { DeveloperPullRequestView(model: model) }
        .task(id: tab) {
            guard !model.chat.loading else { return }
            await model.refresh()
            if tab == .pullRequests { await model.loadPullRequests() }
        }
        .onChange(of: model.chat.responding) { _, value in if !value, tab == .changes { Task { await model.refresh() } } }
    }
    private var changes: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker(L("Comparison"), selection: $model.scope) {
                    Text(L("Agent")).tag(GitDiffScope.agent); Text(L("Working")).tag(GitDiffScope.working); Text(L("Staged")).tag(GitDiffScope.staged); Text(L("Branch")).tag(GitDiffScope.branch)
                }.pickerStyle(.segmented).accessibilityIdentifier("gitDiffScope")
                if model.scope == .branch, let snapshot = model.snapshot {
                    HStack { Text(L("Compare with")).font(.caption).foregroundStyle(MoonStyle.secondary)
                        Picker(L("Base branch"), selection: $model.base) { ForEach(snapshot.branches, id: \.self) { Text($0).tag($0) } }.font(.caption)
                        Spacer()
                    }
                }
                if model.scope != .agent { TextField(L("Filter changed files"), text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled() }
            }.padding(12).disabled(model.busy)
            if model.scope == .agent {
                if let diff = model.chat.latestTurnDiff { DeveloperDiffText(content: diff) }
                else { ContentUnavailableView(L("Latest agent changes"), systemImage: "text.alignleft", description: Text(L("Codex's diff for the latest reply appears here as it edits files. Other changes in your checkout stay in Working or Staged."))) }
            } else if let snapshot = model.snapshot {
                List {
                    ForEach(snapshot.changes.filter { search.isEmpty || $0.path.localizedStandardContains(search) }) { file in
                        HStack(alignment: .top, spacing: 12) {
                            Button { selectedFile = file } label: { DeveloperChangeRow(file: file) }.buttonStyle(.plain)
                            Spacer(minLength: 0)
                            if model.scope != .branch, !file.conflicted {
                                if file.unstaged { stageButton(file, undo: false) }
                                if file.staged { stageButton(file, undo: true) }
                            }
                        }.listRowBackground(Color.clear)
                    }
                    if snapshot.truncated { Text(L("The list is limited to 500 entries. Review larger comparisons on your Mac.")).font(.caption).foregroundStyle(.orange) }
                }.listStyle(.plain).overlay {
                    if snapshot.changes.isEmpty { ContentUnavailableView(L("No changes"), systemImage: "checkmark.circle", description: Text(model.scope == .staged ? L("Stage a changed file to include it here.") : L("This comparison is clean."))) }
                }
            } else if !model.busy {
                ContentUnavailableView(L("Project changes"), systemImage: "doc.text.magnifyingglass", description: Text(L("Open a conversation in a Git checkout, then refresh its project.")))
            }
        }
        .onChange(of: model.scope) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.base) { old, new in if !old.isEmpty, old != new { Task { await model.refresh() } } }
    }
    private func stageButton(_ file: GitChange, undo: Bool) -> some View {
        Button(undo ? L("Unstage") : L("Stage"), systemImage: undo ? "minus.circle" : "plus.circle") { Task { await model.stage(file, undo: undo) } }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.busy || model.chat.responding || model.chat.voiceEngaged)
    }
    private var pullRequests: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L("Pull requests"), selection: $model.allBranches) { Text(L("This branch")).tag(false); Text(L("All branches")).tag(true) }.pickerStyle(.segmented)
                if let snapshot = model.snapshot, snapshot.remotes.count > 1 {
                    Picker(L("Remote"), selection: $model.remote) { ForEach(snapshot.remotes, id: \.self) { Text($0).tag($0) } }.font(.caption)
                }
            }.padding(12).disabled(model.busy)
            Toggle(L("Include closed pull requests"), isOn: $model.includeClosed).font(.caption).padding(.horizontal, 16).padding(.bottom, 10).disabled(model.busy)
            if let forge = model.snapshot?.forge {
                HStack { Label(forge.kind == .github ? "GitHub" : "Azure DevOps", systemImage: "point.3.connected.trianglepath.dotted")
                    Text(forge.organization + "/" + forge.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Refresh PRs"), systemImage: "arrow.clockwise") { Task { await model.loadPullRequests() } }.labelStyle(.iconOnly).disabled(model.busy)
                }.font(.caption).foregroundStyle(MoonStyle.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            }
            List {
                ForEach(model.pullRequests) { request in
                    Button {
                        Task { await model.openPullRequest(request.number); if model.selectedPR != nil { showingPR = true } }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(request.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("#\(request.number) · \(request.author)\(request.draft ? L(" · Draft") : "")").font(.caption).foregroundStyle(MoonStyle.secondary)
                            Text(request.source + " → " + request.target).font(.system(.caption2, design: .monospaced)).foregroundStyle(MoonStyle.secondary).lineLimit(1)
                        }.padding(.vertical, 5)
                    }.disabled(model.busy).listRowBackground(Color.clear)
                }
                if model.hasMorePRs { Button(L("Load more pull requests")) { Task { await model.loadPullRequests(more: true) } }.disabled(model.busy) }
            }.listStyle(.plain).overlay {
                if model.pullRequests.isEmpty, !model.busy {
                    ContentUnavailableView(L("No open pull requests"), systemImage: "arrow.triangle.pull", description: Text(model.snapshot?.forge == nil ? L("Choose a GitHub or Azure DevOps remote and sign in to gh or az on your Mac.") : L("Try All open to see other branches in this repository.")))
                }
            }
        }
        .onChange(of: model.allBranches) { _, _ in Task { await model.loadPullRequests() } }
        .onChange(of: model.includeClosed) { _, _ in Task { await model.loadPullRequests() } }
        .onChange(of: model.remote) { old, new in if !old.isEmpty, old != new { Task { await model.refresh(); await model.loadPullRequests() } } }
    }
}

struct DeveloperChangeRow: View {
    let file: GitChange
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(file.conflicted ? "!" : file.indexStatus == " " ? file.worktreeStatus : file.indexStatus)
                .font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(file.conflicted ? .orange : MoonStyle.mint).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                if let previous = file.previousPath { Text(L("from ") + previous).font(.caption2).foregroundStyle(MoonStyle.secondary) }
            }
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeveloperWorktreesView: View {
    @ObservedObject var model: DeveloperWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var base = ""
    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { Section { DeveloperErrorView(message: error) { model.error = nil } } }
                Section(L("Open a new conversation")) {
                    ForEach(model.snapshot?.worktrees ?? []) { tree in
                        Button { Task { await model.openWorktree(tree); if model.chat.error == nil { dismiss() } } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(tree.branch, systemImage: tree.path == model.snapshot?.root ? "checkmark.circle.fill" : "arrow.triangle.branch")
                                Text(tree.path).font(.system(.caption2, design: .monospaced)).foregroundStyle(MoonStyle.secondary)
                                if tree.locked { Text(L("Locked worktree")).font(.caption2).foregroundStyle(.orange) }
                            }
                        }.disabled(model.busy || model.chat.loading || tree.prunable)
                    }
                }
                Section(L("New worktree")) {
                    TextField(L("Branch name"), text: $branch).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("newWorktreeBranch")
                    Picker(L("Start from"), selection: $base) { ForEach(model.snapshot?.branches ?? [], id: \.self) { Text($0).tag($0) } }
                    Button(L("Create worktree and chat"), systemImage: "plus") {
                        Task {
                            if let tree = await model.createWorktree(branch: branch, base: base) {
                                await model.openWorktree(tree)
                                if model.chat.error == nil { dismiss() }
                            }
                        }
                    }.disabled(branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.isEmpty || model.busy || model.chat.loading)
                        .accessibilityIdentifier("createChatWorktree")
                    Text(L("Your current checkout keeps its changes. The new branch starts from the selected base in its own folder on the Mac.")).font(.caption).foregroundStyle(MoonStyle.secondary)
                }
                if let error = model.chat.error { Section { Text(error).foregroundStyle(.orange).font(.caption) } }
            }.navigationTitle(L("Worktrees")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
                .task { await model.refresh(); base = model.snapshot?.base ?? model.snapshot?.branches.first ?? "" }
        }.presentationDetents([.medium, .large])
    }
}

struct DeveloperFileView: View {
    @ObservedObject var model: DeveloperWorkspaceModel
    let file: GitChange
    let pullRequest: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var original: RepositoryText?
    @State private var text = ""
    @State private var editing = false
    @State private var confirmingDiscard = false
    private var dirty: Bool { editing && original?.text != text }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = model.error { DeveloperErrorView(message: error) { model.error = nil } }
                if model.busy { ProgressView().padding() }
                if editing {
                    TextEditor(text: $text).font(.system(.caption, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("projectFileEditor")
                } else if let content = model.content {
                    DeveloperDiffText(content: content)
                }
            }.navigationTitle(URL(fileURLWithPath: file.path).lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { if dirty { confirmingDiscard = true } else { dismiss() } } }
                    ToolbarItem(placement: .primaryAction) {
                        if editing {
                            Button(L("Save")) { Task { if let original, let saved = await model.saveFile(original, text: text) { self.original = saved; editing = false; await model.loadDiff(file) } } }
                                .disabled(!dirty || model.busy || model.chat.responding || model.chat.voiceEngaged).accessibilityIdentifier("saveProjectFile")
                        } else if pullRequest == nil {
                            Button(L("Edit file")) { Task { if let content = await model.readFile(file.path) { original = content; text = content.text; editing = true } } }
                                .disabled(model.busy || model.chat.responding || model.chat.voiceEngaged)
                        }
                    }
                }
                .task { await model.loadDiff(file, pullRequest: pullRequest) }
                .interactiveDismissDisabled(dirty)
                .confirmationDialog(L("Discard your unsaved edits?"), isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button(L("Discard edits"), role: .destructive) { dismiss() }; Button(L("Keep editing"), role: .cancel) {}
                }
        }
    }
}

struct DeveloperDiffText: View {
    let content: RepositoryText
    var body: some View {
        VStack(spacing: 0) {
            if content.truncated { Text(L("Preview may be incomplete. Open the original comparison for the full diff.")).font(.caption).foregroundStyle(.orange).padding(10) }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(content.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("+") && !line.hasPrefix("+++") ? MoonStyle.mint : line.hasPrefix("-") && !line.hasPrefix("---") ? .red : line.hasPrefix("@@") ? MoonStyle.accent : .primary)
                            .textSelection(.enabled).padding(.horizontal, 12).padding(.vertical, 2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("projectDiff")
        }
    }
}

struct DeveloperPullRequestView: View {
    @ObservedObject var model: DeveloperWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var title = ""
    @State private var bodyText = ""
    @State private var selectedFile: GitChange?
    var body: some View {
        NavigationStack {
            Group {
                if let request = model.selectedPR {
                    Form {
                        if let error = model.error { Section { DeveloperErrorView(message: error) { model.error = nil } } }
                        if editing {
                            Section(L("Title")) { TextField(L("Pull request title"), text: $title, axis: .vertical).accessibilityIdentifier("pullRequestTitle") }
                            Section(L("Description")) { TextEditor(text: $bodyText).frame(minHeight: 260).font(.body).accessibilityIdentifier("pullRequestDescription") }
                        } else {
                            Section {
                                Text(request.title).font(.headline).textSelection(.enabled)
                                Text(NocturneLocalization.pullRequestState(request.state) + (request.draft ? L(" · Draft") : "") + " · " + request.author).font(.caption).foregroundStyle(MoonStyle.secondary)
                                Text(request.source + " → " + request.target).font(.system(.caption, design: .monospaced))
                                if let url = URL(string: request.url), url.scheme == "https" { Link(L("Open in %@", "\(model.snapshot?.forge?.kind == .github ? "GitHub" : "Azure DevOps")"), destination: url) }
                            }
                            Section(L("Description")) { Text(request.body.isEmpty ? L("No description") : request.body).textSelection(.enabled) }
                            if !request.reviewers.isEmpty { Section(L("Reviewers")) { ForEach(request.reviewers, id: \.self) { Text($0).font(.caption) } } }
                            if !request.checks.isEmpty { Section(L("Checks and policies")) { ForEach(Array(request.checks.enumerated()), id: \.offset) { _, check in Text(check).font(.caption) } } }
                            Section(L("Changes")) {
                                ForEach(model.prFiles) { file in Button { selectedFile = file } label: { DeveloperChangeRow(file: file) }.disabled(model.busy) }
                                if model.hasMoreFiles { Button(L("Load more files")) { Task { await model.loadPullRequestFiles() } }.disabled(model.busy) }
                            }
                        }
                    }.navigationTitle(L("PR #%@", "\(request.number)")).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button(editing ? L("Cancel") : L("Done")) { if editing { editing = false } else { dismiss() } } }
                            ToolbarItem(placement: .primaryAction) {
                                if editing {
                                    Button(L("Save PR")) { Task { if await model.savePullRequest(title: title, body: bodyText) { editing = false } } }
                                        .disabled(model.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.chat.responding || model.chat.voiceEngaged)
                                        .accessibilityIdentifier("savePullRequest")
                                } else {
                                    HStack {
                                        Button(L("Refresh PR"), systemImage: "arrow.clockwise") { Task { await model.openPullRequest(request.number) } }.labelStyle(.iconOnly).disabled(model.busy)
                                        Button(L("Edit")) { title = request.title; bodyText = request.body; editing = true }.disabled(model.busy || model.chat.responding || model.chat.voiceEngaged)
                                    }
                                }
                            }
                        }
                } else { ProgressView() }
            }.sheet(item: $selectedFile) { file in DeveloperFileView(model: model, file: file, pullRequest: model.selectedPR?.number) }
        }.interactiveDismissDisabled(editing)
    }
}

private struct DeveloperErrorView: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Dismiss project error"), systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
        }.font(.caption).foregroundStyle(.orange).padding(12).background(MoonStyle.surface)
    }
}
