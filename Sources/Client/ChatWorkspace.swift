import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import NocturneKit

@MainActor
struct ChatWorkspace: View {
    @ObservedObject var model: ChatWorkspaceModel
    @ObservedObject var connection: WorkspaceConnection
    @ObservedObject var voice: ClientVoiceChat
    let connect: () -> Void
    var exit: () -> Void = {}
    private var identity: String {
        connection.connectedInvitation.map { SHA256.hash(data: $0.secret).map { String(format: "%02x", $0) }.joined() } ?? "disconnected"
    }
    var body: some View {
        Group {
            if connection.state != .connected {
                ServerEmptyView(icon: "bubble.left.and.bubble.right", title: "Your conversations.\nWithin reach.", detail: "Connect to your Mac to read and continue your Codex and other agent conversations.", action: connect)
            } else if !connection.capabilities.contains(ChatProtocol.capability) {
                ContentUnavailableView("Allow chat access", systemImage: "bubble.left.and.bubble.right", description: Text("Enable Agent chats in Nocturne on your Mac, then reconnect."))
            } else {
                ChatBarEnvironment { usesSystemBar in
                    ChatWorkspaceCanvas(chat: model, connection: connection, voice: voice, scope: identity + "." + model.providerID, usesSystemBar: usesSystemBar, exit: exit)
                }.id(identity + "." + model.providerID)
            }
        }.task(id: connection.state) { if connection.state == .connected { await model.refresh() } }
            .toolbar {
                if connection.state != .connected || !connection.capabilities.contains(ChatProtocol.capability) {
                    ToolbarItem(placement: .topBarLeading) { Button("Nocturne", systemImage: "chevron.left", action: exit) }
                }
            }
    }
}

private struct ChatBarEnvironment<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @ViewBuilder var body: some View {
        if #available(iOS 27.1, *) { ChatVerticalBarEnvironment(content: content) }
        else { content(false) }
    }
}

@available(iOS 27.1, *)
private struct ChatVerticalBarEnvironment<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(edge != nil) }
}

private enum ChatWorkspaceMode { case threads, pullRequests }
private enum ChatWorkspaceSheet: String, Identifiable {
    case worktrees, changes, terminal, files, git, prEditor
    var id: String { rawValue }
}

@MainActor
private struct ChatWorkspaceCanvas: View {
    @ObservedObject var chat: ChatWorkspaceModel
    @ObservedObject var connection: WorkspaceConnection
    @ObservedObject var voice: ClientVoiceChat
    @StateObject private var project: DeveloperWorkspaceModel
    @StateObject private var inbox: PullRequestInboxModel
    @StateObject private var navigation: ChatNavigationState
    let usesSystemBar: Bool
    let exit: () -> Void
    @AppStorage("nocturne.chat.dark") private var darkChat = true
    @State private var mode = ChatWorkspaceMode.threads
    @State private var sidebar: Bool
    @State private var sheet: ChatWorkspaceSheet?
    @State private var importing = false
    @State private var selectedPRURL: String?
    @State private var prHelper: ChatPRHelper?
    @State private var watchingPR = false
    @FocusState private var composing: Bool
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(chat: ChatWorkspaceModel, connection: WorkspaceConnection, voice: ClientVoiceChat, scope: String, usesSystemBar: Bool, exit: @escaping () -> Void) {
        self.chat = chat; self.connection = connection; self.voice = voice; self.usesSystemBar = usesSystemBar; self.exit = exit
        _project = StateObject(wrappedValue: DeveloperWorkspaceModel(chat: chat))
        _inbox = StateObject(wrappedValue: PullRequestInboxModel(chat: chat))
        _navigation = StateObject(wrappedValue: ChatNavigationState(scope: scope))
        _sidebar = State(initialValue: chat.selected == nil)
    }
    private var locked: Bool { chat.loading || chat.loadingOlder || chat.responding || chat.voiceEngaged || chat.configuring }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900 || (geometry.size.width >= 740 && geometry.size.width > geometry.size.height)
            let sidebarWidth = min(440, max(280, geometry.size.width * 0.32))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if wide, sidebar { side(wide: true).frame(width: sidebarWidth) }
                    main(wide: wide).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !wide, sidebar {
                    ChatStyle.canvas.opacity(0.55).ignoresSafeArea().onTapGesture { sidebar = false }
                    side(wide: false).frame(width: min(340, geometry.size.width - 44)).transition(.move(edge: .leading)).shadow(color: .black.opacity(0.35), radius: 24)
                }
            }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: sidebar)
                .onAppear { if wide { sidebar = true } }
                .onChange(of: wide) { _, value in sidebar = value }
        }
        .background(ChatStyle.canvas.ignoresSafeArea()).environment(\.colorScheme, darkChat ? .dark : systemScheme).preferredColorScheme(darkChat ? .dark : nil).tint(ChatStyle.blue)
        .navigationTitle(usesSystemBar ? "" : "Chats")
        .toolbar(usesSystemBar ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarColorScheme(darkChat ? .dark : nil, for: .navigationBar, .bottomBar)
        .toolbar { if #available(iOS 27.1, *), usesSystemBar { systemToolbar } }
        .sheet(item: $sheet) { destination in sheetContent(destination).preferredColorScheme(darkChat ? .dark : nil) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .sourceCode], allowsMultipleSelection: true, onCompletion: importFiles)
        .task(id: (chat.selected?.id ?? "") + String(chat.loading)) { if mode == .threads, chat.selected != nil, chat.selected?.isSupervisor != true, !chat.loading { await project.refresh() } }
        .task(id: chat.draft) {
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            saveDraft()
        }
        .onChange(of: chat.responding) { old, value in if old, !value, mode == .threads, chat.selected?.isSupervisor != true { Task { await project.refresh() } } }
        .onDisappear { saveDraft() }
    }
    @ViewBuilder private func sheetContent(_ destination: ChatWorkspaceSheet) -> some View {
        switch destination {
        case .worktrees: DeveloperWorktreesView(model: project)
        case .changes: NavigationStack { DeveloperProjectPane(model: project, tab: .changes).navigationTitle("Review changes").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { sheet = nil } } } }
        case .terminal: NavigationStack { TerminalWorkspace(connection: connection, connect: {}).navigationTitle("Terminal").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { sheet = nil } } } }
        case .files: NavigationStack { FilesWorkspace(connection: connection, connect: {}).navigationTitle("Files").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { sheet = nil } } } }
        case .git: ChatGitActionsView(project: project) {
            selectedPRURL = project.selectedPR?.url; mode = .pullRequests; sheet = nil
            Task { await inbox.refresh() }
        }
        case .prEditor: DeveloperPullRequestView(model: project)
        }
    }
    @ViewBuilder private func side(wide: Bool) -> some View {
        if mode == .threads {
            ChatThreadSidebar(chat: chat, project: project, navigation: navigation, openSupervisor: { openSupervisor(wide: wide) }, newThread: { newThread(wide: wide) }, open: { openThread($0, wide: wide) }, exit: exit, saveDraft: saveDraft, darkChat: $darkChat, showsControls: !usesSystemBar)
        } else { ChatPRSidebar(inbox: inbox, selectedURL: selectedPRURL, selectionDisabled: locked || project.busy, open: { openPR($0, wide: wide) }, settings: { mode = .threads }, showsControls: !usesSystemBar) }
    }
    private func main(wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if !usesSystemBar {
                    ChatCircleButton(title: sidebar && wide ? "Expand conversation" : "Show sidebar", symbol: sidebar && wide ? "arrow.up.left.and.arrow.down.right" : "sidebar.left", action: toggleSidebar).modifier(ChatGlass()).accessibilityIdentifier("chatSidebarToggle")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .pullRequests ? project.selectedPR.map { "#\($0.number)" } ?? "Pull requests" : threadTitle).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(mode == .pullRequests ? (selectedPRURL == nil ? "GitHub & Azure DevOps" : project.snapshot?.forge.map { $0.organization + "/" + $0.name } ?? "Pull request") : projectName + " · " + connection.name).font(.caption).foregroundStyle(ChatStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.leading, 20).padding(.trailing, usesSystemBar ? 20 : 74).padding(.top, 12).padding(.bottom, 12)
            if mode == .threads {
                if chat.messages.isEmpty, !chat.loading {
                    if chat.selected?.isSupervisor == true { supervisorHero } else { newThreadHero }
                }
                else { ChatTranscript(model: chat).padding(.trailing, usesSystemBar ? 0 : (wide ? 60 : 48)) }
            } else if project.selectedPR != nil, selectedPRURL != nil {
                ChatPullRequestWorkspace(project: project, chat: chat, showThread: { mode = .threads }, helper: $prHelper, watching: $watchingPR).padding(.trailing, usesSystemBar ? 0 : (wide ? 82 : 60))
            } else { ChatEmptyState(symbol: "sidebar.left", title: "Select a pull request", detail: "Choose a pull request from the sidebar to review it.") }
            if let permission = chat.permissions.first { permissionView(permission).padding(.trailing, !usesSystemBar && wide ? 80 : 0) }
            if let error = chat.error { errorView(error) { chat.error = nil } }
            if let error = voice.error { errorView(error) { voice.dismissError() } }
            if let notice = chat.voiceContinuationNotice {
                HStack(alignment: .top) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(notice)
                    Spacer(minLength: 0)
                    Button(action: chat.dismissVoiceContinuationNotice) { Image(systemName: "xmark") }.accessibilityLabel("Dismiss voice notice")
                }.font(.caption).foregroundStyle(ChatStyle.secondary).padding(12).background(ChatStyle.surface).padding(.horizontal, 16)
            }
            if voice.engaged { voiceControls.padding(.trailing, !usesSystemBar && wide ? 80 : 0).padding(.horizontal, 16).padding(.bottom, 12) }
            else if mode == .threads { composer(wide: wide) }
        }.background(ChatStyle.canvas).overlay(alignment: .trailing) { if !usesSystemBar { tools(wide: wide) } }
    }
    private var projectName: String { chat.selected?.isSupervisor == true ? "All agents" : ChatStyle.projectName(project.snapshot?.root ?? chat.selected?.directory ?? "") }
    private var threadTitle: String {
        guard let selected = chat.selected else { return "New thread" }
        if selected.isSupervisor == true { return ChatSupervisor.title }
        if chat.messages.isEmpty { return "New thread" }
        if selected.title == "New conversation", let first = chat.messages.first(where: { $0.role == .user }) { return String(first.text.prefix(90)) }
        return navigation.title(selected)
    }
    private var supervisorHero: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 38, weight: .light)).foregroundStyle(ChatStyle.purple)
            Text("One conversation. All your agents.").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("Ask for progress, send a fix to a project, or start a new feature.").font(.subheadline).foregroundStyle(ChatStyle.secondary).multilineTextAlignment(.center)
            Toggle("Start voice when opened", isOn: $navigation.supervisorStartsVoice).font(.subheadline).frame(maxWidth: 300)
                .accessibilityIdentifier("supervisorAutoVoice")
            Spacer(); Spacer().frame(maxHeight: 60)
        }.padding(28).padding(.trailing, usesSystemBar ? 0 : 60).frame(maxWidth: .infinity)
    }
    private var newThreadHero: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 10) {
                Text("What should we build").font(.system(size: 26, weight: .medium))
                HStack(spacing: 0) {
                    Text("in ").font(.system(size: 26, weight: .medium))
                    Button { sidebar = true } label: { Text(projectName).underline(color: ChatStyle.secondary).font(.system(size: 26, weight: .medium)) }.buttonStyle(.plain)
                    Text("?").font(.system(size: 26, weight: .medium))
                }
            }.multilineTextAlignment(.center)
            Label("on " + connection.name, systemImage: "laptopcomputer").font(.subheadline).foregroundStyle(ChatStyle.secondary)
            if chat.selected == nil { Button("New thread", systemImage: "plus") { newThread(wide: false) }.buttonStyle(.borderedProminent).disabled(locked || chat.provider?.available != true).accessibilityIdentifier("startProjectThread") }
            Spacer(); Spacer().frame(maxHeight: 80)
        }.padding(.horizontal, 24).padding(.trailing, usesSystemBar ? 0 : 60).frame(maxWidth: .infinity)
    }
    @ViewBuilder private var gitActions: some View {
        Section(project.snapshot?.branch ?? "Git") {
            if connection.capabilities.contains(DeveloperProtocol.actionsCapability) { Button("Commit, push & PR", systemImage: "arrow.up.right.circle") { sheet = .git }.disabled(locked) }
            Button("Review changes", systemImage: "text.bubble") { sheet = .changes }
            Button("Worktrees", systemImage: "arrow.triangle.branch") { sheet = .worktrees }.disabled(locked)
            Button("Refresh project", systemImage: "arrow.clockwise") { Task { await project.refresh() } }
            if let branch = project.snapshot?.branch { Button("Copy branch", systemImage: "doc.on.doc") { UIPasteboard.general.string = branch } }
        }
    }
    @ViewBuilder private var prHelperActions: some View {
        if let request = project.selectedPR {
            Button("Explain this PR", systemImage: "book") { prHelper = .explain }
            Button("Address feedback", systemImage: "wrench.and.screwdriver") { prHelper = .feedback }.disabled(!["open", "active"].contains(request.state) || project.snapshot?.branch != request.source)
            Button("Resolve conflicts", systemImage: "arrow.triangle.branch") { prHelper = .conflicts }.disabled(request.mergeable != false || project.snapshot?.branch != request.source)
        }
    }
    @ViewBuilder private var prActions: some View {
        if let request = project.selectedPR {
            if let url = URL(string: request.url), url.scheme == "https" { Link("Open on " + (project.snapshot?.forge?.kind == .github ? "GitHub" : "Azure DevOps"), destination: url); ShareLink("Share…", item: url) }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.string = request.url }
            Button("Edit title and description", systemImage: "pencil") { sheet = .prEditor }.disabled(locked || project.busy)
            Button(watchingPR ? "Stop watching" : "Watch while open", systemImage: "eye") { watchingPR.toggle() }
            Button("Worktrees", systemImage: "arrow.triangle.branch") { sheet = .worktrees }.disabled(locked)
            Button("Refresh PR", systemImage: "arrow.clockwise") { Task { await project.openPullRequest(request.number) } }.disabled(project.busy)
        }
    }
    @available(iOS 27.1, *)
    @ToolbarContentBuilder private var systemToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(sidebar ? "Hide sidebar" : "Show sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                .accessibilityIdentifier("chatSidebarToggle")
        }.visibilityPriority(.high)
        ToolbarItem(placement: .topBarPinnedTrailing) {
            if mode == .threads {
                Button("New thread", systemImage: "square.and.pencil") { newThread(wide: true) }.disabled(locked || chat.provider?.available != true)
            } else if selectedPRURL != nil {
                Button("Back to pull requests", systemImage: "chevron.left") { selectedPRURL = nil; watchingPR = false; project.closePullRequest() }
            }
        }.visibilityPriority(.high)
        ToolbarItemGroup(placement: .topBarTrailing) {
            if mode == .threads, chat.selected != nil, chat.selected?.isSupervisor != true {
                Button("Terminal", systemImage: "terminal") { composing = false; sheet = .terminal }.disabled(!connection.capabilities.contains("terminal"))
                Menu { gitActions } label: { Label("Git tools", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }.accessibilityIdentifier("chatGitTools")
                Button("Files", systemImage: "folder") { composing = false; sheet = .files }.disabled(!connection.capabilities.contains("files"))
            } else if selectedPRURL != nil {
                Menu { prHelperActions } label: { Label("PR agent helpers", systemImage: "bubble.left.and.bubble.right") }.disabled(locked || project.busy || !chat.canPrompt)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Button("Threads", systemImage: "bubble.left") { composing = false; mode = .threads }.tint(mode == .threads ? ChatStyle.blue : .primary).accessibilityIdentifier("chatThreadsMode")
            Button("Pull requests", systemImage: "arrow.triangle.pull", action: showPullRequests).tint(mode == .pullRequests ? ChatStyle.blue : .primary).accessibilityIdentifier("chatPullRequestsMode")
        }.visibilityPriority(.high)
        ToolbarOverflowMenu {
            if mode == .pullRequests, selectedPRURL != nil { Section("Pull request") { prActions } }
            ChatSettingsActions(chat: chat, darkChat: $darkChat, saveDraft: saveDraft, exit: exit)
        }
    }
    private func toggleSidebar() { composing = false; sidebar.toggle() }
    private func showPullRequests() {
        composing = false; mode = .pullRequests; sidebar = true
        if inbox.items.isEmpty { Task { await inbox.refresh() } }
    }
    private func tools(wide: Bool) -> some View {
        VStack(spacing: 14) {
            if mode == .threads {
                ChatCircleButton(title: "New thread", symbol: "square.and.pencil") { newThread(wide: wide) }.modifier(ChatGlass()).disabled(locked || chat.provider?.available != true)
            } else if project.selectedPR != nil, selectedPRURL != nil {
                ChatCircleButton(title: "Back to pull requests", symbol: "chevron.left") { selectedPRURL = nil; watchingPR = false; project.closePullRequest() }.modifier(ChatGlass())
                Menu { prHelperActions } label: { Image(systemName: "bubble.left.and.bubble.right").font(.title3).frame(width: 44, height: 44).modifier(ChatGlass()) }.disabled(locked || project.busy || !chat.canPrompt).accessibilityLabel("PR agent helpers")
                Menu { prActions } label: { Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44).modifier(ChatGlass()) }.accessibilityLabel("Pull request actions")
            }
            if chat.selected != nil, chat.selected?.isSupervisor != true, mode == .threads {
                VStack(spacing: 2) {
                    ChatCircleButton(title: "Terminal", symbol: "terminal") { sheet = .terminal }.disabled(!connection.capabilities.contains("terminal"))
                    Menu { gitActions } label: { Image(systemName: "point.topleft.down.curvedto.point.bottomright.up").font(.system(size: 21)).foregroundStyle(Color.primary).frame(width: 44, height: 44) }.accessibilityLabel("Git tools").accessibilityIdentifier("chatGitTools")
                    ChatCircleButton(title: "Files", symbol: "folder") { sheet = .files }.disabled(!connection.capabilities.contains("files"))
                }.padding(3).modifier(ChatGlass())
            }
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                ChatCircleButton(title: "Threads", symbol: "bubble.left", selected: mode == .threads) { composing = false; mode = .threads }.accessibilityIdentifier("chatThreadsMode")
                ChatCircleButton(title: "Pull requests", symbol: "arrow.triangle.pull", selected: mode == .pullRequests, action: showPullRequests).accessibilityIdentifier("chatPullRequestsMode")
            }.padding(3).modifier(ChatGlass())
        }.padding(.top, 12).padding(.bottom, wide ? 24 : (mode == .threads ? 170 : 20)).padding(.trailing, 12).frame(width: 64)
    }
    private func composer(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected = chat.selected, selected.isSupervisor != true, project.snapshot != nil {
                HStack(spacing: 14) {
                    Label("Current checkout", systemImage: "folder")
                    Button { sheet = .worktrees } label: { Label(project.snapshot?.branch ?? "Checkout", systemImage: "arrow.triangle.branch").lineLimit(1) }.disabled(locked)
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(ChatStyle.secondary).accessibilityIdentifier("chatCheckout").accessibilityValue(selected.directory)
            }
            if chat.draft.hasPrefix("/"), !chat.draft.contains(" ") {
                ScrollView(.horizontal, showsIndicators: false) { HStack {
                    ForEach(ChatSlashCommand.allCases.filter { ("/" + $0.rawValue).hasPrefix(chat.draft) }) { command in
                        Button("/" + command.rawValue) { chat.draft = "/" + command.rawValue; send() }.buttonStyle(.bordered).font(.caption)
                    }
                } }
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("Attach text files", systemImage: "paperclip") { importing = true }
                        Button("Files on your Mac", systemImage: "folder") { sheet = .files }
                        Button("New worktree", systemImage: "arrow.triangle.branch") { sheet = .worktrees }.disabled(chat.selected == nil)
                    } label: { Image(systemName: "plus").font(.system(size: 24, weight: .light)).foregroundStyle(Color.primary).frame(width: 44, height: 44) }.disabled(locked)
                    TextField(chat.selected?.isSupervisor == true ? "Tell the supervisor what to do…" : "Ask the repo agent…", text: $chat.draft, axis: .vertical).lineLimit(1...6).font(.system(size: 16)).padding(.vertical, 12).frame(minHeight: 44).focused($composing).disabled(chat.loading || chat.loadingOlder || chat.responding || chat.configuring || chat.selected == nil).accessibilityIdentifier("chatComposer").onSubmit(send)
                    if chat.supportsVoice {
                        Button { voice.start() } label: { Image(systemName: "mic").font(.title3).frame(width: 44, height: 44) }.disabled(locked).accessibilityLabel("Start voice chat").accessibilityIdentifier("startVoiceChat")
                    }
                    Button { if chat.responding { Task { await chat.stop() } } else { send() } } label: {
                        Image(systemName: chat.responding ? "stop.fill" : "arrow.up").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44).background(chat.responding ? Color.red.opacity(0.8) : ChatStyle.blue.opacity(chat.draft.isEmpty ? 0.28 : 0.9), in: Circle())
                    }.disabled(!chat.responding && (locked || chat.selected == nil || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)).keyboardShortcut(.return, modifiers: .command).accessibilityLabel(chat.responding ? "Stop reply" : "Send message").accessibilityIdentifier(chat.responding ? "stopChat" : "sendChat")
                }
                if !chat.options.isEmpty || chat.optionsError != nil {
                    Divider().overlay(Color.primary.opacity(0.06))
                    ChatConfigurationBar(model: chat, inline: true).padding(.horizontal, 12).padding(.vertical, 6)
                }
            }.padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
        }.padding(.leading, 20).padding(.trailing, !usesSystemBar && wide ? 80 : 20).padding(.bottom, 14).padding(.top, 8)
    }
    private func saveDraft() { if let selected = chat.selected, !chat.loading { navigation.saveDraft(chat.draft, for: selected.id) } }
    private func openSupervisor(wide: Bool) {
        guard !locked else { return }; composing = false; saveDraft(); mode = .threads
        Task {
            await chat.openSupervisor()
            guard chat.selected?.isSupervisor == true, chat.error == nil else { return }
            if let id = chat.selected?.id { chat.draft = navigation.entry(id).draft ?? "" }
            if !wide { sidebar = false }
            voice.startSupervisorIfEnabled(navigation.supervisorStartsVoice)
        }
    }
    private func newThread(wide: Bool) {
        guard !locked else { return }; composing = false; saveDraft(); mode = .threads
        Task { await chat.newConversation(inheritProject: true); if !wide { sidebar = false } }
    }
    private func openThread(_ session: ChatSessionInfo, wide: Bool) {
        if session.isSupervisor == true { openSupervisor(wide: wide); return }
        guard !locked else { return }; composing = false; saveDraft(); mode = .threads
        Task { await chat.open(session); if chat.error == nil { chat.draft = navigation.entry(session.id).draft ?? "" }; if !wide { sidebar = false } }
    }
    private func openPR(_ item: PullRequestInboxModel.Item, wide: Bool) {
        guard !locked, !project.busy else { return }; saveDraft(); watchingPR = false
        Task {
            let sameRepository = project.snapshot?.worktrees.contains { $0.path == item.session.directory } == true
            if chat.selected == nil || !sameRepository { await chat.open(item.session) }
            guard chat.selected != nil, chat.error == nil else { return }
            project.remote = item.remote; await project.refresh(); await project.openPullRequest(item.request.number)
            if project.selectedPR != nil { selectedPRURL = item.id; if !wide { sidebar = false } }
        }
    }
    private func send() {
        if let command = ChatSlashCommand.parse(chat.draft) {
            chat.draft = ""
            switch command {
            case .new: newThread(wide: true)
            case .changes: sheet = .changes
            case .worktrees: sheet = .worktrees
            case .terminal: sheet = .terminal
            case .files: sheet = .files
            case .pr: mode = .pullRequests; sidebar = true; Task { await inbox.refresh() }
            }
        } else { saveDraft(); Task { await chat.send() } }
    }
    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let files = try result.get(); var text = chat.draft
            guard files.count <= 8 else { throw NocturneError.remote("Attach up to eight text files at a time.") }
            for file in files {
                let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_384 else { throw NocturneError.remote("Attach text files up to 16 KB each.") }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count <= 16_384, !data.contains(0), let contents = String(data: data, encoding: .utf8) else { throw NocturneError.remote("Attach UTF-8 text files up to 16 KB each.") }
                text += "\n\nFile: " + file.lastPathComponent + "\n```\n" + contents + "\n```"
            }
            guard text.utf8.count <= ChatProtocol.maximumPromptBytes else { throw NocturneError.remote("The attached text is too large for one message.") }
            chat.draft = text
        } catch { chat.error = error.localizedDescription }
    }
    private func errorView(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(message).textSelection(.enabled); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error") }.font(.caption).foregroundStyle(.orange).padding(12).background(ChatStyle.surface).padding(.horizontal, 16)
    }
    private func permissionView(_ permission: ChatPermission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(permission.title, systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            ScrollView { Text(permission.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
            ViewThatFits(in: .horizontal) {
                HStack { ForEach(permission.options) { permissionButton(permission, $0) } }
                VStack(alignment: .leading) { ForEach(permission.options) { permissionButton(permission, $0) } }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 18)).padding(12)
    }
    private func permissionButton(_ permission: ChatPermission, _ option: ChatPermissionOption) -> some View {
        Button(option.title, role: option.destructive ? .destructive : nil) { Task { await chat.decide(permission, option: option) } }.buttonStyle(.bordered).font(.subheadline)
    }
    private var voiceControls: some View {
        HStack(spacing: 12) {
            Image(systemName: voice.speaking ? "waveform" : voice.muted ? "mic.slash" : "mic.fill").foregroundStyle(voice.muted ? ChatStyle.secondary : ChatStyle.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(voice.starting ? "Connecting voice…" : voice.ending ? "Ending voice chat…" : voice.muted ? "Microphone muted" : voice.speaking ? "Codex is speaking" : "Listening").font(.subheadline.weight(.semibold)).accessibilityIdentifier("voiceStatus")
                Text("You can interrupt Codex while it speaks.").font(.caption).foregroundStyle(ChatStyle.secondary)
            }
            Spacer(minLength: 0)
            Button { voice.toggleMuted() } label: { Image(systemName: voice.muted ? "mic.slash.fill" : "mic.fill").frame(width: 40, height: 44) }.disabled(!voice.active).accessibilityLabel(voice.muted ? "Unmute microphone" : "Mute microphone").accessibilityIdentifier("voiceMute")
            Button(role: .destructive) { voice.end() } label: { Image(systemName: "phone.down.fill").frame(width: 40, height: 44) }.disabled(voice.ending).accessibilityLabel("End voice chat").accessibilityIdentifier("endVoiceChat")
        }.padding(16).modifier(ChatGlass())
    }
}
