import SwiftUI
import NocturneKit

@MainActor
struct ChatWorkspace: View {
    @ObservedObject var model: ChatWorkspaceModel
    @ObservedObject var connection: WorkspaceConnection
    @ObservedObject var voice: ClientVoiceChat
    let connect: () -> Void
    @State private var search = ""
    @StateObject private var project: DeveloperWorkspaceModel
    @State private var tab = DeveloperProjectPane.Tab.conversation
    @State private var showingWorktrees = false
    init(model: ChatWorkspaceModel, connection: WorkspaceConnection, voice: ClientVoiceChat, connect: @escaping () -> Void) {
        self.model = model; self.connection = connection; self.voice = voice; self.connect = connect
        _project = StateObject(wrappedValue: DeveloperWorkspaceModel(chat: model))
    }

    var body: some View {
        Group {
            if connection.state != .connected {
                ServerEmptyView(icon: "bubble.left.and.bubble.right", title: "Your conversations.\nWithin reach.",
                    detail: "Connect to your Mac to read and continue your Codex and other agent conversations.", action: connect)
            } else if !connection.capabilities.contains(ChatProtocol.capability) {
                ContentUnavailableView("Allow chat access", systemImage: "bubble.left.and.bubble.right",
                    description: Text("On your Mac, open Nocturne Server → Sharing and enable Agent chats. Then reconnect. Update the Mac server if this option is missing."))
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        providerBar
                        if model.selected != nil, connection.capabilities.contains(DeveloperProtocol.capability) {
                            DeveloperContextBar(project: project, chat: model, showingWorktrees: $showingWorktrees)
                            Picker("Workspace view", selection: $tab) {
                                ForEach(DeveloperProjectPane.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.bottom, 10).accessibilityIdentifier("agentWorkspaceTabs")
                        }
                        Divider()
                        if tab != .conversation, model.selected != nil {
                            DeveloperProjectPane(model: project, tab: tab)
                        } else if geometry.size.width >= 760 {
                            HStack(spacing: 0) {
                                conversations.frame(width: 290)
                                Divider()
                                conversation
                            }
                        } else if model.selected != nil { conversation }
                        else { conversations }
                        if let error = model.error {
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.circle")
                                Text(error).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly)
                            }.font(.caption).foregroundStyle(.orange).padding(12).background(MoonStyle.surface)
                        }
                    }
                }
            }
        }
        .task(id: connection.state) { if connection.state == .connected { await model.refresh() } }
        .task(id: (model.selected?.id ?? "") + String(model.loading)) {
            if model.selected != nil, !model.loading, connection.capabilities.contains(DeveloperProtocol.capability) { await project.refresh() }
        }
        .onChange(of: model.selected?.id) { _, value in if value == nil { tab = .conversation } }
        .sheet(isPresented: $showingWorktrees) { DeveloperWorktreesView(model: project) }
        .background { NocturneBackdrop() }
    }
    private var providerBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Provider", selection: Binding(get: { model.providerID }, set: { id in Task { await model.chooseProvider(id) } })) {
                    ForEach(model.providers) { provider in
                        Label(provider.name + (provider.available ? "" : " · Setup needed"), systemImage: "bubble.left.and.bubble.right").tag(provider.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(model.provider?.name ?? "Codex").fontWeight(.semibold)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }.disabled(model.responding || model.loading || model.voiceEngaged).accessibilityLabel("Chat provider").accessibilityIdentifier("chatProvider")
            Spacer(minLength: 0)
            if model.loading { ProgressView().controlSize(.small) }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .labelStyle(.iconOnly).disabled(model.loading || model.responding || model.voiceEngaged)
            Button("New conversation", systemImage: "square.and.pencil") { Task { await model.newConversation() } }
                .labelStyle(.iconOnly).disabled(model.loading || model.responding || model.voiceEngaged || model.provider?.available != true)
                .accessibilityIdentifier("newChat")
        }.font(.subheadline).padding(.horizontal, 18).padding(.vertical, 14)
    }
    private var conversations: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(MoonStyle.secondary)
                TextField("Filter loaded chats", text: $search).textFieldStyle(.plain).autocorrectionDisabled()
                if !search.isEmpty { Button("Clear filter", systemImage: "xmark.circle.fill") { search = "" }.labelStyle(.iconOnly) }
            }.font(.subheadline).padding(12).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 12)).padding(12)
            if model.providerID == "codex" {
                Picker("Conversations", selection: Binding(get: { model.archived }, set: { value in Task { await model.showArchived(value) } })) {
                    Text("Recent").tag(false); Text("Archived").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.bottom, 10).disabled(model.responding || model.loading || model.voiceEngaged)
            }
            if let provider = model.provider, !provider.available {
                ContentUnavailableView("Set up \(provider.name)", systemImage: "desktopcomputer", description: Text(provider.detail))
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.sessions.filter { search.isEmpty || $0.title.localizedStandardContains(search) || $0.directory.localizedStandardContains(search) }) { session in
                            Button { Task { await model.open(session) } } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(session.title).font(.system(.subheadline, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack {
                                        Text(URL(fileURLWithPath: session.directory).lastPathComponent).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                                        Spacer(minLength: 5)
                                        if let date = session.updatedAt { Text(date, style: .relative).font(.caption2).lineLimit(1) }
                                    }.foregroundStyle(MoonStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                    .background(model.selected?.id == session.id ? MoonStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 14))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.responding || model.loading || model.voiceEngaged)
                        }
                        if model.hasMoreSessions {
                            Button("Load more conversations") { Task { await model.moreSessions() } }
                                .font(.subheadline).padding(16).disabled(model.loading || model.responding || model.voiceEngaged)
                        }
                        if model.sessions.isEmpty && !model.loading {
                            ContentUnavailableView("No conversations yet", systemImage: "bubble.left",
                                description: Text(model.archived ? "Your archived Codex conversations will appear here." : "Start a conversation, or open your agent on the Mac and refresh."))
                        }
                        if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(MoonStyle.secondary).padding(16) }
                    }.padding(.horizontal, 8)
                }.refreshable { await model.refresh() }
            }
        }.frame(maxHeight: .infinity)
    }
    @ViewBuilder private var conversation: some View {
        if let selected = model.selected {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Button("Conversations", systemImage: "chevron.left") { model.leaveConversation() }
                        .labelStyle(.iconOnly).disabled(model.responding || model.loading || model.voiceEngaged)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(selected.directory).font(.system(.caption2, design: .monospaced)).foregroundStyle(MoonStyle.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if model.supportsVoice, !voice.engaged {
                        Button("Start voice chat", systemImage: "waveform") { voice.start() }
                            .labelStyle(.iconOnly).disabled(model.loading || model.responding)
                            .accessibilityIdentifier("startVoiceChat")
                    }
                }.padding(16)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if model.hasOlderMessages {
                                Button("Load older messages") { Task { await model.open(selected, older: true) } }
                                    .font(.caption).frame(maxWidth: .infinity).disabled(model.loading || model.responding || model.voiceEngaged)
                            }
                            ForEach(model.messages) { message in
                                ChatMessageRow(message: message, providerName: model.provider?.name ?? "Agent").id(message.id)
                            }
                            if model.responding {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.permissions.isEmpty ? "Replying…" : "Waiting for your decision") }
                                    .font(.caption).foregroundStyle(MoonStyle.secondary)
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(20).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.messages.last?.id) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                    .onChange(of: model.messages.last?.text.count) { _, _ in if model.responding { proxy.scrollTo("latest", anchor: .bottom) } }
                }
                if let permission = model.permissions.first { permissionView(permission) }
                if let error = voice.error {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Dismiss voice error", systemImage: "xmark") { voice.dismissError() }.labelStyle(.iconOnly)
                    }.foregroundStyle(.orange).padding(12)
                }
                if voice.engaged { voiceControls }
                else if model.canPrompt { ChatConfigurationBar(model: model); composer }
                else if model.archived { Text("Archived conversation").font(.caption).foregroundStyle(MoonStyle.secondary).padding(12) }
            }
        } else {
            ContentUnavailableView("Pick up a conversation", systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a chat from your Mac, or start a new one with \(model.provider?.name ?? "Codex")."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message \(model.provider?.name ?? "agent")", text: $model.draft, axis: .vertical)
                .lineLimit(1...6).padding(12).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 15))
                .accessibilityIdentifier("chatComposer").disabled(model.responding)
            if model.responding {
                Button("Stop reply", systemImage: "stop.fill") { Task { await model.stop() } }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).accessibilityIdentifier("stopChat")
            } else {
                Button("Send message", systemImage: "arrow.up.circle.fill") { Task { await model.send() } }
                    .font(.system(size: 32)).labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(model.loading || model.configuring || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("sendChat")
            }
        }.padding(12).background(.ultraThinMaterial)
    }
    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: voice.speaking ? "waveform" : voice.muted ? "mic.slash" : "mic.fill")
                    .foregroundStyle(voice.muted ? MoonStyle.secondary : MoonStyle.mint).frame(width: 24)
                Text(voice.starting ? "Connecting voice…" : voice.ending ? "Ending voice chat…" : voice.muted ? "Microphone muted" : voice.speaking ? "Codex is speaking" : "Listening")
                    .font(.subheadline.weight(.semibold)).accessibilityIdentifier("voiceStatus")
                Spacer(minLength: 0)
                Button(voice.muted ? "Unmute microphone" : "Mute microphone", systemImage: voice.muted ? "mic.slash.fill" : "mic.fill") { voice.toggleMuted() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(!voice.active)
                    .accessibilityIdentifier("voiceMute")
                Button("End voice chat", systemImage: "phone.down.fill", role: .destructive) { voice.end() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(voice.ending)
                    .accessibilityIdentifier("endVoiceChat")
            }
            Text("Talk naturally. You can interrupt Codex while it speaks.").font(.caption).foregroundStyle(MoonStyle.secondary)
        }.padding(16).background(.ultraThinMaterial)
    }
    private func permissionView(_ permission: ChatPermission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(permission.title, systemImage: "hand.raised").font(.subheadline.weight(.semibold))
            ScrollView { Text(permission.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            ViewThatFits(in: .horizontal) {
                HStack { ForEach(permission.options) { option in permissionButton(permission, option) } }
                VStack(alignment: .leading) { ForEach(permission.options) { option in permissionButton(permission, option) } }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(MoonStyle.accent.opacity(0.10))
    }
    private func permissionButton(_ permission: ChatPermission, _ option: ChatPermissionOption) -> some View {
        Button(option.title, role: option.destructive ? .destructive : nil) { Task { await model.decide(permission, option: option) } }
            .buttonStyle(.bordered).font(.subheadline)
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let providerName: String
    var body: some View {
        if message.role == .tool {
            DisclosureGroup {
                Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                Label(String(message.text.prefix(100).split(separator: "\n").first ?? "Tool activity"), systemImage: "terminal")
                    .font(.caption).lineLimit(1)
            }.foregroundStyle(MoonStyle.secondary)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text(message.role == .user ? "You" : message.role == .assistant ? providerName : "Activity")
                    .font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(MoonStyle.secondary)
                Text(message.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(message.role == .user ? 14 : 0)
                .background(message.role == .user ? MoonStyle.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
