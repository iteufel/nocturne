import SwiftUI
import SwiftTerm
import Combine
import NocturneKit

struct TerminalWorkspace: View {
    @ObservedObject var connection: WorkspaceConnection
    let connect: () -> Void
    var immersive = false
    var exit: (() -> Void)? = nil
    var hostPicker: AnyView? = nil
    @State private var opening = false
    @State private var error: String?
    @State private var closing: Set<String> = []
    @State private var visible = false
    @State private var showsControls = false
    var body: some View {
        VStack(spacing: 0) {
            if !connection.terminals.isEmpty {
                if !immersive {
                    if connection.state != .connected { connectionHeader }
                    tabBar
                }
                ZStack {
                    ForEach(connection.terminals) { tab in
                        TerminalPane(connection: connection, tab: tab, immersive: immersive, selected: visible && !showsControls && connection.terminalID == tab.id, reportError: { error = $0 })
                            .opacity(connection.terminalID == tab.id ? 1 : 0)
                            .allowsHitTesting(connection.terminalID == tab.id)
                            .accessibilityHidden(connection.terminalID != tab.id)
                    }
                }.padding(.horizontal, immersive ? 0 : 4).padding(.bottom, immersive ? 0 : 4)
            } else if connection.state == .connecting {
                Spacer(); ProgressView(L("Restoring your terminals…")); Spacer()
            } else if connection.state != .connected {
                ServerEmptyView(icon: "terminal", title: L("Pick up where\nyou left off."), detail: L("Connect to your Mac to open a shell or return to your running terminals."), action: connect)
            } else if !connection.capabilities.contains("terminal") {
                ContentUnavailableView(L("Allow terminal access"), systemImage: "terminal", description: Text(L("Enable Terminal in Nocturne on your Mac, then reconnect.")))
            } else {
                Spacer()
                Image(systemName: "terminal").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(MoonStyle.accent)
                Text(L("At your command")).font(.system(size: 24, weight: .semibold, design: .rounded)).padding(.top, 12)
                Text(L("Your shells keep running on your Mac when you leave."))
                    .font(.subheadline).foregroundStyle(MoonStyle.secondary).multilineTextAlignment(.center).padding(.horizontal, 28).padding(.top, 5)
                Button(action: openTerminal) {
                    HStack { if opening { ProgressView() }; Text(opening ? L("Opening…") : L("Open terminal")) }
                }.buttonStyle(PrimaryButtonStyle()).disabled(opening).padding(.top, 22)
                Spacer()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(12) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if immersive { MoonStyle.terminalInk.ignoresSafeArea() }
                else { NocturneBackdrop() }
            }
            .toolbar(immersive ? .hidden : .automatic, for: .navigationBar, .bottomBar)
            .overlay(alignment: .topTrailing) {
                if immersive {
                    TerminalControlsButton { showsControls = true }
                        .frame(width: 44, height: 44).padding(8)
                }
            }
            .sheet(isPresented: $showsControls) { controls }
            .accessibilityAction(named: L("Terminal")) { showsControls = true }
            .onAppear { visible = true }.onDisappear { visible = false }
            .onChange(of: connection.state) { _, state in if state == .connected { error = nil } }
    }
    private var controls: some View {
        NavigationStack {
            List {
                if let exit {
                    Section {
                        Button("Nocturne", systemImage: "chevron.left") { showsControls = false; exit() }
                            .accessibilityIdentifier("terminalExit")
                    }
                }
                if let hostPicker { Section { hostPicker } }
                if connection.state != .connected { Section { connectionHeader } }
                Section {
                    ForEach(connection.terminals) { tab in
                        HStack {
                            Button {
                                connection.selectTerminal(tab.id); showsControls = false
                            } label: {
                                Label(tab.info.name, systemImage: connection.terminalID == tab.id ? "checkmark" : "terminal")
                            }
                            Spacer()
                            Button { closeTerminal(tab.id) } label: { Image(systemName: "xmark") }
                                .disabled(connection.state != .connected || closing.contains(tab.id))
                                .accessibilityLabel(L("Close %@", tab.info.name))
                        }.buttonStyle(.borderless)
                    }
                    Button(L("New terminal"), systemImage: "plus") { openTerminal(); showsControls = false }
                        .disabled(opening || connection.state != .connected || connection.terminals.count >= WorkspaceProtocol.maximumTerminals)
                }
            }.navigationTitle(L("Terminal")).navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showsControls = false } } }
        }.presentationDetents([.medium, .large])
    }
    private var connectionHeader: some View {
        HStack(spacing: 8) {
            Circle().fill(connection.state == .connected ? MoonStyle.mint : MoonStyle.secondary).frame(width: 6, height: 6)
            Text(connection.name).lineLimit(1)
            Spacer(minLength: 4)
            if connection.state == .connecting { ProgressView().controlSize(.small); Text(L("Reconnecting…")) }
            else if connection.state == .disconnected { Button(L("Reconnect"), action: connect).buttonStyle(.borderless) }
            else { Image(systemName: "lock.fill").font(.system(size: 10)) }
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(MoonStyle.secondary)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }
    private var tabBar: some View {
        HStack(spacing: 6) {
            Circle().fill(connection.state == .connected ? MoonStyle.mint : MoonStyle.secondary)
                .frame(width: 6, height: 6)
                .accessibilityLabel(connection.name)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    NocturneGlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(connection.terminals) { tab in
                                TerminalTabButton(tab: tab, selected: connection.terminalID == tab.id,
                                    canClose: connection.state == .connected && !closing.contains(tab.id),
                                    select: { connection.selectTerminal(tab.id) }, close: { closeTerminal(tab.id) })
                                    .id(tab.id)
                            }
                        }.padding(.vertical, 2).padding(.horizontal, 2)
                    }
                }.scrollIndicators(.hidden)
                    .onChange(of: connection.terminalID) { _, id in if let id { proxy.scrollTo(id, anchor: .trailing) } }
            }
            Button(action: openTerminal) {
                if opening { ProgressView().frame(width: 28, height: 28) }
                else { Image(systemName: "plus").frame(width: 28, height: 28) }
            }.buttonStyle(NocturneGlassButtonStyle()).accessibilityLabel(L("New terminal"))
                .disabled(opening || connection.state != .connected || connection.terminals.count >= WorkspaceProtocol.maximumTerminals)
        }.padding(.horizontal, 10)
    }
    private func openTerminal() {
        opening = true; error = nil
        Task { defer { opening = false }; do { try await connection.openTerminal() } catch { self.error = NocturneLocalization.message(error.localizedDescription) } }
    }
    private func closeTerminal(_ id: String) {
        closing.insert(id); error = nil
        Task { defer { closing.remove(id) }; do { try await connection.closeTerminal(id) } catch { self.error = NocturneLocalization.message(error.localizedDescription) } }
    }
}

// Keep this action reachable while the software keyboard or SwiftTerm's alternate keyboard is open.
// It overlays the canvas instead of reserving a navigation row.
private struct TerminalControlsButton: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: "ellipsis")
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = UIColor(MoonStyle.accent)
        button.configuration = configuration
        button.accessibilityLabel = L("Terminal")
        button.accessibilityIdentifier = "terminalControls"
        button.addAction(UIAction { [weak button] _ in
            button?.window?.endEditing(true)
            action()
        }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}

private struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Image(systemName: tab.info.running ? "terminal" : "checkmark.circle")
                    Text(tab.info.name).lineLimit(1)
                }.padding(.leading, 14).padding(.trailing, 6).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityLabel(tab.info.name + (tab.info.running ? "" : L(", ended")))
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 36, height: 44).contentShape(Rectangle())
            }.disabled(!canClose).accessibilityLabel(L("Close %@", tab.info.name))
        }.buttonStyle(.plain).font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? MoonStyle.accent : MoonStyle.secondary)
            .background(selected ? MoonStyle.accent.opacity(0.13) : .clear, in: Capsule())
            .nocturneGlass(in: Capsule(), interactive: true)
            .overlay(Capsule().strokeBorder(selected ? MoonStyle.accent.opacity(0.45) : .clear, lineWidth: 1))
    }
}

private struct TerminalPane: View {
    @ObservedObject var connection: WorkspaceConnection
    @ObservedObject var tab: TerminalTab
    let immersive: Bool
    let selected: Bool
    let reportError: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            TerminalSurface(connection: connection, tab: tab, active: selected && connection.state == .connected && tab.info.running, reportError: reportError)
                .padding(immersive ? 0 : 6).frame(maxWidth: .infinity, maxHeight: .infinity)
            if !tab.info.running {
                Text(L("Session ended")).font(.caption).foregroundStyle(MoonStyle.terminalText.opacity(0.7)).padding(10)
            } else if connection.state != .connected {
                Text(L("Reconnect to continue. Your shell stays on your Mac."))
                    .font(.caption).foregroundStyle(MoonStyle.terminalText.opacity(0.7)).padding(10)
            }
        }.background(MoonStyle.terminalInk, in: RoundedRectangle(cornerRadius: immersive ? 0 : 18))
            .clipShape(RoundedRectangle(cornerRadius: immersive ? 0 : 18))
    }
}

struct ServerEmptyView: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Spacer()
            Image(systemName: icon).font(.system(size: 48, weight: .ultraLight)).foregroundStyle(MoonStyle.accent)
            Text(title).font(.system(size: 37, weight: .semibold, design: .rounded)).tracking(-1.2)
            Text(detail).font(.system(size: 15)).foregroundStyle(MoonStyle.secondary).lineSpacing(5)
            Button(action: action) { Label(L("Connect your Mac"), systemImage: "link") }.buttonStyle(PrimaryButtonStyle())
            Spacer()
            Label(L("Encrypted between your devices"), systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(MoonStyle.secondary)
        }.padding(32).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct TerminalSurface: UIViewRepresentable {
    let connection: WorkspaceConnection
    let tab: TerminalTab
    let active: Bool
    let reportError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(connection: connection, tab: tab, reportError: reportError) }
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = SwiftTerm.TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular))
        // Pull down can also dismiss the keyboard; the controls button remains available without this gesture.
        terminal.keyboardDismissMode = .interactive
        terminal.alwaysBounceVertical = true
        terminal.nativeBackgroundColor = UIColor(MoonStyle.terminalInk); terminal.nativeForegroundColor = UIColor(MoonStyle.terminalText)
        terminal.terminalDelegate = context.coordinator
        terminal.resize(cols: tab.info.columns, rows: tab.info.rows)
        context.coordinator.replaying = true
        terminal.feed(byteArray: ArraySlice(tab.history))
        context.coordinator.replaying = false
        context.coordinator.subscription = tab.output.sink { [weak terminal, weak coordinator = context.coordinator] update in
            guard let terminal, let coordinator else { return }
            switch update {
            case .append(let data): terminal.feed(byteArray: ArraySlice(data))
            case .reset(let data):
                coordinator.replaying = true
                terminal.resetToInitialState(); terminal.feed(byteArray: ArraySlice(data))
                coordinator.replaying = false
            }
        }
        return terminal
    }
    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        let becameActive = active && !context.coordinator.active
        context.coordinator.active = active
        if !active { uiView.resignFirstResponder() }
        // Layout may have changed while disconnected or while another tab was selected.
        if becameActive {
            let terminal = uiView.terminalDimensions
            context.coordinator.sizeChanged(source: uiView, newCols: terminal.cols, newRows: terminal.rows)
            DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
                guard coordinator?.active == true, let uiView, uiView.window != nil else { return }
                uiView.becomeFirstResponder()
            }
        }
    }
    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) { coordinator.stop(); uiView.terminalDelegate = nil }
    final class Coordinator: NSObject, TerminalViewDelegate {
        let connection: WorkspaceConnection
        let tab: TerminalTab
        var subscription: AnyCancellable?
        var active = false
        var replaying = false
        let reportError: (String) -> Void
        private var resizeTask: Task<Void, Never>?
        init(connection: WorkspaceConnection, tab: TerminalTab, reportError: @escaping (String) -> Void) {
            self.connection = connection; self.tab = tab; self.reportError = reportError
        }
        func stop() { subscription = nil; resizeTask?.cancel(); active = false }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            resizeTask?.cancel()
            guard active else { return }
            resizeTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    guard active else { return }
                    try await connection.resizeTerminal(columns: newCols, rows: newRows, sessionID: tab.id)
                }
                catch is CancellationError {} catch { reportError(NocturneLocalization.message(error.localizedDescription)) }
            }
        }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard active, !replaying else { return }
            Task { @MainActor in do { try await connection.terminalInput(Data(data), sessionID: tab.id) } catch { reportError(NocturneLocalization.message(error.localizedDescription)) } }
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        // Remote terminal escape sequences do not silently open URLs or read/write the local clipboard.
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
