import SwiftUI
import NocturneKit

enum ChatPRHelper: String { case explain, feedback, conflicts }

struct ChatPullRequestWorkspace: View {
    @ObservedObject var project: DeveloperWorkspaceModel
    @ObservedObject var chat: ChatWorkspaceModel
    let showThread: () -> Void
    @Binding var helper: ChatPRHelper?
    @Binding var watching: Bool
    @State private var tab = "Overview"
    @State private var editing = false
    @State private var selectedFile: GitChange?
    @State private var guideStart: Int?
    @Environment(\.scenePhase) private var scenePhase
    private var locked: Bool { project.busy || chat.responding || chat.loading || chat.voiceEngaged || chat.configuring }
    private var guide: String {
        guard let guideStart, guideStart <= chat.messages.count else { return "" }
        return chat.messages.dropFirst(guideStart).filter { $0.role == .assistant }.map(\.text).joined(separator: "\n\n")
    }
    var body: some View {
        Group {
            if let request = project.selectedPR {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 10) {
                            Label(state(request), systemImage: "arrow.triangle.pull").foregroundStyle(ChatStyle.prColor(request.state)).font(.caption.weight(.semibold))
                            Text(LCount("%d files", request.fileCount ?? project.prFiles.count)).font(.caption).foregroundStyle(ChatStyle.secondary)
                            Spacer()
                        }
                        Text(request.title).font(.system(size: 23, weight: .semibold)).textSelection(.enabled)
                        HStack(alignment: .firstTextBaseline) {
                            Text(request.author).font(.subheadline)
                            Spacer()
                            if let date = ChatStyle.date(request.updatedAt) { Text(L("Updated %@", ChatStyle.age(date))).font(.caption).foregroundStyle(ChatStyle.secondary) }
                        }
                        Text(request.target + " ← " + request.source).font(.system(.caption, design: .monospaced)).foregroundStyle(ChatStyle.secondary).textSelection(.enabled)
                        HStack(spacing: 0) {
                            ForEach(["Overview", "Guide", "Activity"], id: \.self) { value in
                                Button { tab = value } label: {
                                    Text(L(value)).font(.subheadline.weight(tab == value ? .semibold : .regular)).foregroundStyle(tab == value ? Color.primary : ChatStyle.secondary)
                                        .padding(.horizontal, 18).padding(.vertical, 11).background(tab == value ? ChatStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? [.isSelected] : []).accessibilityIdentifier("prTab-" + value)
                            }
                        }.padding(3).accessibilityIdentifier("prWorkspaceTabs")
                        if watching { Label(L("Watching while this PR is open"), systemImage: "eye").font(.caption).foregroundStyle(ChatStyle.blue) }
                        if let error = project.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        if project.busy { ProgressView().controlSize(.small) }
                        switch tab {
                        case "Guide": guideView(request)
                        case "Activity": activityView
                        default: overview(request)
                        }
                    }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                }
                .task(id: tab + request.url) { if tab == "Activity" { await project.loadActivity() } }
                .task(id: String(watching) + request.url) {
                    guard watching else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                        guard project.selectedPR?.url == request.url else { return }
                        if scenePhase == .active, !locked { await refresh(request.number) }
                    }
                }
                .onChange(of: request.url) { _, _ in guideStart = nil; watching = false; tab = "Overview" }
                .onChange(of: helper) { _, value in if let value { runHelper(value, request: request); helper = nil } }
            } else { ProgressView() }
        }
        .sheet(item: $selectedFile) { file in DeveloperFileView(model: project, file: file, pullRequest: project.selectedPR?.number) }
        .sheet(isPresented: $editing) { DeveloperPullRequestView(model: project) }
    }
    private func state(_ request: PullRequestInfo) -> String {
        if request.draft { return L("Draft") }
        return ["completed", "merged"].contains(request.state) ? L("Merged") : NocturneLocalization.pullRequestState(request.state)
    }
    private func overview(_ request: PullRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 20) {
                DisclosureGroup {
                    ForEach(Array(request.checks.enumerated()), id: \.offset) { _, check in Text(check).font(.caption).padding(.vertical, 5) }
                } label: { Label(request.checks.isEmpty ? L("No checks reported") : LCount("%d checks and policies", request.checks.count), systemImage: request.checks.isEmpty ? "minus" : "checkmark.circle").font(.subheadline) }.tint(ChatStyle.secondary)
                DisclosureGroup {
                    if request.reviewers.isEmpty { Text(L("No reviewers assigned")).font(.caption).foregroundStyle(ChatStyle.secondary) }
                    ForEach(request.reviewers, id: \.self) { reviewer in Text(reviewer).font(.caption).padding(.vertical, 5) }
                } label: { Label(L("Reviewers"), systemImage: "person.2").font(.subheadline) }.tint(ChatStyle.secondary)
                if let mergeable = request.mergeable {
                    Label(mergeable ? L("No conflicts with %@", request.target) : L("Conflicts with %@", request.target), systemImage: mergeable ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(mergeable ? ChatStyle.green : .orange)
                }
                if ["merged", "completed", "closed", "abandoned"].contains(request.state) {
                    Text(L("This pull request is %@.", state(request))).font(.caption).foregroundStyle(ChatStyle.secondary)
                }
            }.padding(22).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Description")).font(.headline)
                ChatMarkdown(text: request.body.isEmpty ? L("No description provided.") : request.body)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(L("Changes")).font(.headline); Spacer(); if let n = request.additions { Text("+\(n)").foregroundStyle(ChatStyle.green) }; if let n = request.deletions { Text("−\(n)").foregroundStyle(.red) } }
                ForEach(project.prFiles) { file in
                    Button { selectedFile = file } label: { DeveloperChangeRow(file: file).padding(.horizontal, 14).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).disabled(project.busy)
                }
                if project.hasMoreFiles { Button(L("Load more files")) { Task { await project.loadPullRequestFiles() } }.disabled(project.busy) }
            }
            Menu {
                Button(L("Explain this PR"), systemImage: "book") { runHelper(.explain, request: request) }
                Button(L("Address feedback"), systemImage: "wrench.and.screwdriver") { runHelper(.feedback, request: request) }.disabled(!["open", "active"].contains(request.state) || project.snapshot?.branch != request.source)
                Button(L("Resolve conflicts"), systemImage: "arrow.triangle.branch") { runHelper(.conflicts, request: request) }.disabled(request.mergeable != false || project.snapshot?.branch != request.source)
            } label: { Label(L("Ask the agent"), systemImage: "sparkles").padding(.horizontal, 18).padding(.vertical, 12).modifier(ChatGlass()) }.disabled(locked || !chat.canPrompt).accessibilityIdentifier("prAgentHelpers")
            if project.snapshot?.branch != request.source { Text(L("Open the PR's source checkout in Worktrees to address feedback or conflicts.")).font(.caption).foregroundStyle(ChatStyle.secondary) }
        }
    }
    private func guideView(_ request: PullRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L("Review guide"), systemImage: "list.number").font(.headline)
            if guide.isEmpty {
                Text(L("Get a tour of the change, with code excerpts and notes on what needs attention.")).font(.subheadline).foregroundStyle(ChatStyle.secondary).lineSpacing(5)
            } else { ChatMarkdown(text: guide) }
            if chat.responding, guideStart != nil {
                HStack { ProgressView(); Text(L("Writing guide…")).font(.caption); Spacer(); Button(L("Stop")) { Task { await chat.stop() } } }
            } else {
                Button(guide.isEmpty ? L("Write guide") : L("Rewrite guide")) {
                    guideStart = chat.messages.count; send(PullRequestAgentPrompt.make(request, files: project.prFiles, activity: [], task: .guide), reveal: false)
                }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).disabled(locked || !chat.canPrompt).accessibilityIdentifier("writeReviewGuide")
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    private var activityView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if project.activity.isEmpty, !project.busy {
                Text(chat.connection.capabilities.contains(DeveloperProtocol.actionsCapability) ? L("No comments or reviews returned.") : L("Update Nocturne on your Mac to load PR activity.")).font(.subheadline).foregroundStyle(ChatStyle.secondary)
            }
            ForEach(project.activity) { activity in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(activity.author).font(.subheadline.weight(.medium)); Spacer(); if let date = ChatStyle.date(activity.createdAt) { Text(date, style: .relative).font(.caption).foregroundStyle(ChatStyle.secondary) } }
                    if let path = activity.path { Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(ChatStyle.secondary) }
                    ChatMarkdown(text: activity.text)
                }.padding(18).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
    private func refresh(_ number: Int) async { await project.openPullRequest(number); if tab == "Activity" { await project.loadActivity() } }
    private func runHelper(_ helper: ChatPRHelper, request: PullRequestInfo) {
        Task {
            if helper == .feedback { await project.loadActivity() }
            let task: PullRequestAgentPrompt.Task = helper == .explain ? .explain : helper == .feedback ? .feedback : .conflicts
            send(PullRequestAgentPrompt.make(request, files: project.prFiles, activity: project.activity, task: task), reveal: true)
        }
    }
    private func send(_ prompt: String, reveal: Bool) {
        guard !locked, chat.canPrompt else { return }
        Task { await chat.sendHelper(prompt) }
        if reveal { showThread() }
    }
}
