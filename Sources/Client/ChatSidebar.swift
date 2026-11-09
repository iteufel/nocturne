import SwiftUI
import NocturneKit

struct ChatSettingsActions: View {
    @ObservedObject var chat: ChatWorkspaceModel
    @Binding var darkChat: Bool
    let saveDraft: () -> Void
    let exit: () -> Void
    private var locked: Bool { chat.loading || chat.loadingOlder || chat.responding || chat.voiceEngaged || chat.configuring }
    var body: some View {
        Section("Provider") {
            ForEach(chat.providers) { provider in
                Button { saveDraft(); Task { await chat.chooseProvider(provider.id) } } label: {
                    Label(provider.name + (provider.available ? "" : " · Setup needed"), systemImage: provider.id == chat.providerID ? "checkmark" : "circle")
                }.disabled(locked)
            }
        }
        if chat.providerID == "codex" {
            Button(chat.archived ? "Recent threads" : "Archived threads", systemImage: "archivebox") { saveDraft(); Task { await chat.showArchived(!chat.archived) } }.disabled(locked)
        }
        Button("Refresh threads", systemImage: "arrow.clockwise") { Task { await chat.refresh() } }.disabled(locked)
        Toggle("Dark chat", isOn: $darkChat)
        Divider()
        Button("Back to Nocturne", systemImage: "desktopcomputer", action: exit)
    }
}

struct ChatThreadSidebar: View {
    @ObservedObject var chat: ChatWorkspaceModel
    @ObservedObject var project: DeveloperWorkspaceModel
    @ObservedObject var navigation: ChatNavigationState
    let openSupervisor: () -> Void
    let newThread: () -> Void
    let open: (ChatSessionInfo) -> Void
    let exit: () -> Void
    let saveDraft: () -> Void
    @Binding var darkChat: Bool
    var showsControls = true
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var renaming: ChatSessionInfo?
    @State private var title = ""
    private var locked: Bool { chat.loading || chat.loadingOlder || chat.responding || chat.voiceEngaged || chat.configuring }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nocturne").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                if showsControls {
                    Menu { ChatSettingsActions(chat: chat, darkChat: $darkChat, saveDraft: saveDraft, exit: exit) }
                    label: { Image(systemName: "gearshape").font(.title3).foregroundStyle(Color.primary).frame(width: 44, height: 44).modifier(ChatGlass()) }
                        .accessibilityLabel("Chat settings").accessibilityIdentifier("chatSettings")
                }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
            if chat.supportsSupervisor {
                HStack(spacing: 4) {
                    Button(action: openSupervisor) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark").font(.title2).foregroundStyle(ChatStyle.purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Supervisor").font(.system(size: 17, weight: .semibold))
                                if let session = chat.selected, session.isSupervisor == true, let activity = chat.activity(for: session.id) { activityLabel(activity) }
                                else { Text("Manage your agents").font(.caption).foregroundStyle(ChatStyle.secondary) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: navigation.supervisorStartsVoice ? "mic.fill" : "pin.fill").font(.caption).foregroundStyle(ChatStyle.secondary)
                        }.padding(.vertical, 14).padding(.leading, 16).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(locked).accessibilityIdentifier("chatSupervisor")
                    Menu {
                        Toggle("Start voice when opened", isOn: $navigation.supervisorStartsVoice)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(ChatStyle.secondary) }
                        .accessibilityLabel("Supervisor settings").accessibilityIdentifier("supervisorSettings")
                }.background(chat.selected?.isSupervisor == true ? ChatStyle.selected : ChatStyle.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 8).padding(.bottom, 18)
            }
            HStack {
                Text(chat.archived ? "Archived" : chat.provider?.name ?? "Threads").font(.caption).foregroundStyle(ChatStyle.secondary)
                Spacer()
                if showsControls { Button("New thread", systemImage: "square.and.pencil", action: newThread).labelStyle(.iconOnly).font(.title3).disabled(locked || chat.provider?.available != true).accessibilityIdentifier("newChat") }
            }.padding(.horizontal, 24).padding(.bottom, 14)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                List {
                        ForEach([ChatNavigationState.Group.recent, .working, .snoozed, .settled], id: \.rawValue) { group in
                            let sessions = chat.sessions.filter {
                                $0.isSupervisor != true && navigation.group($0.id, active: chat.responding || chat.voiceEngaged ? chat.selected?.id : nil, now: timeline.date) == group &&
                                (search.isEmpty || navigation.title($0).localizedStandardContains(search) || $0.directory.localizedStandardContains(search))
                            }
                            if !sessions.isEmpty {
                                if group != .recent {
                                    Button { if !collapsed.insert(group.rawValue).inserted { collapsed.remove(group.rawValue) } } label: {
                                        HStack(spacing: 10) {
                                            Text(group.rawValue).font(.caption)
                                            Rectangle().fill(group == .snoozed ? ChatStyle.blue.opacity(0.35) : Color.primary.opacity(0.12)).frame(height: 1)
                                            Image(systemName: collapsed.contains(group.rawValue) ? "chevron.down" : "chevron.up").font(.caption2)
                                        }.foregroundStyle(ChatStyle.secondary).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 10)
                                    }.buttonStyle(.plain).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                                }
                                if !collapsed.contains(group.rawValue) {
                                    ForEach(sessions) { session in
                                        row(session, group: group)
                                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                                if group != .working {
                                                    Button { navigation.settle(session.id, group != .settled) } label: {
                                                        Label(group == .settled ? "Reopen" : "Settle", systemImage: group == .settled ? "arrow.uturn.backward" : "checkmark")
                                                    }.tint(ChatStyle.green)
                                                }
                                            }
                                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                                if group != .working {
                                                    Button { navigation.snooze(session.id, until: group == .snoozed ? nil : Date().addingTimeInterval(3600)) } label: {
                                                        Label(group == .snoozed ? "Wake" : "Snooze", systemImage: group == .snoozed ? "sun.max" : "moon")
                                                    }.tint(ChatStyle.purple)
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        if chat.hasMoreSessions { Button("Load more threads") { Task { await chat.moreSessions() } }.font(.caption).padding(20).disabled(locked) }
                        if chat.loading { ProgressView().frame(maxWidth: .infinity).padding(20) }
                        if chat.sessions.isEmpty, !chat.loading { Text(chat.provider?.available == false ? chat.provider?.detail ?? "Set up the agent on your Mac." : "Start a thread to work on your project.").font(.caption).foregroundStyle(ChatStyle.secondary).padding(24) }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(ChatStyle.secondary)
                TextField("Search threads", text: $search).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("Search loaded threads")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }.padding(16).modifier(ChatGlass()).padding(16)
        }.background(ChatStyle.sidebar)
            .alert("Rename thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let renaming { navigation.rename(renaming.id, title: title) }; renaming = nil }
            }
    }
    private func activityLabel(_ activity: ChatActivity) -> some View {
        HStack(spacing: 5) {
            if activity.isActive { ProgressView().controlSize(.mini) }
            else { Image(systemName: activity.phase == .waiting ? "hand.raised.fill" : activity.phase == .failed ? "exclamationmark.circle.fill" : activity.phase == .stopped ? "stop.circle" : "checkmark.circle") }
            Text(activity.detail).font(.caption2.weight(.semibold)).lineLimit(2)
        }.foregroundStyle(activity.phase == .failed || activity.phase == .waiting ? Color.orange : ChatStyle.blue)
            .accessibilityElement(children: .combine).accessibilityIdentifier("chatActivityStatus")
    }
    private func row(_ session: ChatSessionInfo, group: ChatNavigationState.Group) -> some View {
        Button { open(session) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ChatProjectMark(name: ChatStyle.projectName(session.directory))
                    Text(ChatStyle.projectName(session.directory)).font(.caption).foregroundStyle(ChatStyle.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let activity = chat.activity(for: session.id) {
                        activityLabel(activity)
                    } else if let date = session.updatedAt { Text(ChatStyle.age(date)).font(.caption2).foregroundStyle(ChatStyle.secondary).lineLimit(1) }
                }
                Text(navigation.title(session)).font(.system(size: 17, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if session.id == chat.selected?.id, let branch = project.snapshot?.branch {
                        Text(branch).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                        Image(systemName: "laptopcomputer").font(.caption2)
                    } else { Text(URL(fileURLWithPath: session.directory).lastPathComponent).font(.system(.caption2, design: .monospaced)).lineLimit(1) }
                    Spacer()
                    if session.id == chat.selected?.id, let request = project.selectedPR, request.source == project.snapshot?.branch { Label("\(request.number)", systemImage: "arrow.triangle.pull").foregroundStyle(ChatStyle.prColor(request.state)) }
                    Image(systemName: "circle.hexagongrid").font(.caption)
                }.foregroundStyle(ChatStyle.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(chat.selected?.id == session.id ? ChatStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(locked && chat.selected?.id != session.id)
            .contextMenu {
                Button("Rename", systemImage: "pencil") { title = navigation.title(session); renaming = session }
                if group == .snoozed { Button("Wake thread", systemImage: "sun.max") { navigation.snooze(session.id, until: nil) } }
                else { Button("Snooze for an hour", systemImage: "moon") { navigation.snooze(session.id, until: Date().addingTimeInterval(3600)) }.disabled(group == .working) }
                Button(group == .settled ? "Reopen thread" : "Mark settled", systemImage: "checkmark.circle") { navigation.settle(session.id, group != .settled) }.disabled(group == .working)
            }
    }
}

struct ChatPRSidebar: View {
    @ObservedObject var inbox: PullRequestInboxModel
    let selectedURL: String?
    var selectionDisabled = false
    let open: (PullRequestInboxModel.Item) -> Void
    let settings: () -> Void
    var showsControls = true
    @State private var search = ""
    @State private var status = "Open"
    @State private var repository = ""
    @State private var author = ""
    @State private var label = ""
    private var filtered: [PullRequestInboxModel.Item] {
        inbox.items.filter { item in
            let request = item.request, isOpen = ["open", "active"].contains(request.state)
            return (status == "All" || (status == "Open" ? isOpen : !isOpen)) &&
                (repository.isEmpty || item.repository.webURL == repository) && (author.isEmpty || request.author == author) &&
                (label.isEmpty || request.labels?.contains(label) == true) &&
                (search.isEmpty || (request.title + " \(request.number) " + item.repository.name + " " + request.author).localizedStandardContains(search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nocturne").font(.system(size: 22, weight: .semibold, design: .rounded)); Spacer()
                if showsControls { Button(action: settings) { Image(systemName: "bubble.left.and.bubble.right").font(.title3).frame(width: 44, height: 44).modifier(ChatGlass()) }.accessibilityLabel("Back to threads") }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filter(status, selection: $status, values: ["Open", "Closed", "All"])
                    Menu {
                        Button("All repositories") { repository = "" }
                        ForEach(Array(Set(inbox.items.map { $0.repository.webURL })).sorted(), id: \.self) { url in
                            Button(inbox.items.first { $0.repository.webURL == url }?.repository.name ?? url) { repository = url }
                        }
                    } label: { chip(repository.isEmpty ? "All PRs" : inbox.items.first { $0.repository.webURL == repository }?.repository.name ?? "Repository") }
                    filter(label.isEmpty ? "Labels" : label, selection: $label, values: [""] + Array(Set(inbox.items.flatMap { $0.request.labels ?? [] })).sorted())
                    filter(author.isEmpty ? "Author" : author, selection: $author, values: [""] + Array(Set(inbox.items.map { $0.request.author })).sorted())
                }.padding(.horizontal, 16)
            }.padding(.bottom, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(filtered) { item in
                        Button { open(item) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "arrow.triangle.pull").font(.title3).foregroundStyle(ChatStyle.prColor(item.request.state)).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(item.repository.name + " #\(item.request.number) · " + (item.repository.kind == .github ? "GitHub" : "Azure")).lineLimit(1)
                                        Spacer(minLength: 4)
                                        if let date = ChatStyle.date(item.request.updatedAt) { Text(ChatStyle.age(date)).lineLimit(1) }
                                    }.font(.caption).foregroundStyle(ChatStyle.secondary)
                                    Text(item.request.title).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.leading).lineLimit(3)
                                    if item.request.additions != nil || item.request.deletions != nil {
                                        HStack(spacing: 8) { Spacer(); if let n = item.request.additions { Text("+\(n)").foregroundStyle(ChatStyle.green) }; if let n = item.request.deletions { Text("−\(n)").foregroundStyle(.red) } }.font(.caption)
                                    }
                                }
                            }.padding(16).background(item.id == selectedURL ? ChatStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).disabled(selectionDisabled)
                    }
                    if inbox.hasMore { Button("Load more pull requests") { Task { await inbox.more() } }.font(.caption).padding(20).disabled(inbox.busy) }
                    if inbox.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking repositories…").font(.caption).foregroundStyle(ChatStyle.secondary) }.frame(maxWidth: .infinity).padding(16) }
                    if filtered.isEmpty, !inbox.busy { Text(inbox.items.isEmpty ? "No pull requests found in your loaded projects." : "No pull requests match these filters.").font(.caption).foregroundStyle(ChatStyle.secondary).padding(24) }
                    ForEach(inbox.errors, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange).padding(12) }
                }.padding(.horizontal, 8)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(ChatStyle.secondary)
                TextField("Search pull requests", text: $search).autocorrectionDisabled()
                Button { Task { await inbox.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(inbox.busy).accessibilityLabel("Refresh pull requests")
            }.padding(16).modifier(ChatGlass()).padding(16)
        }.background(ChatStyle.sidebar)
    }
    private func chip(_ text: String) -> some View { HStack(spacing: 6) { Text(text).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }.font(.caption).foregroundStyle(Color.primary.opacity(0.8)).padding(.horizontal, 12).padding(.vertical, 9).modifier(ChatGlass()) }
    private func filter(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Menu { ForEach(values, id: \.self) { value in Button(value.isEmpty ? "All" : value) { selection.wrappedValue = value } } } label: { chip(title) }
    }
}
