import SwiftUI

/// Desktop-only entry point, shared by the iOS and Mac viewers.
public struct MacUnlockControl: View {
    @ObservedObject private var connection: WorkspaceConnection
    @StateObject private var model: MacUnlockModel
    @Environment(\.scenePhase) private var scenePhase
    private let enabled: Bool
    private let presentationChanged: (Bool) -> Void
    public init(connection: WorkspaceConnection, enabled: Bool = true, presentationChanged: @escaping (Bool) -> Void = { _ in }) {
        self.connection = connection; self.enabled = enabled; self.presentationChanged = presentationChanged
        _model = StateObject(wrappedValue: MacUnlockModel(connection: connection))
    }
    public var body: some View {
        HStack(spacing: 0) {
            if enabled, model.supported, model.status?.state == .locked {
                Button(L("Unlock Mac"), systemImage: "lock.open") { model.present() }
                    .accessibilityIdentifier("unlockMac")
            }
        }
        .sheet(isPresented: Binding(get: { model.isPresented }, set: { if !$0 { model.dismiss() } })) {
            MacUnlockPrompt(model: model)
        }
        .task(id: enabled && model.supported) {
            guard enabled, model.supported else { model.dismiss(); return }
            while !Task.isCancelled, model.supported {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
        .onChange(of: model.isPresented) { _, presented in presentationChanged(presented) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.dismiss() } }
        .onDisappear { model.dismiss(); presentationChanged(false) }
    }
}

private struct MacUnlockPrompt: View {
    @ObservedObject var model: MacUnlockModel
    @FocusState private var passwordFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(L("Unlock %@", model.connection.name), systemImage: "lock.open")
                    .font(.title2.bold()).accessibilityIdentifier("macUnlockTitle")
                Text(L("Enter the Mac login password for %@.", model.status?.user ?? ""))
                SecureField(L("Mac login password"), text: $model.password)
                    .textContentType(.password).autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder).privacySensitive()
                    .focused($passwordFocused).disabled(model.isSubmitting)
                    .accessibilityIdentifier("macUnlockPassword")
                    .onSubmit { model.submit() }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Text(L("Nocturne sends this password only to this paired Mac over the encrypted connection. It is not saved. This unlocks an existing sign-in; it cannot unlock FileVault after a restart."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("macUnlockError") }
                HStack {
                    Button(L("Cancel"), role: .cancel) { model.dismiss() }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("macUnlockCancel")
                    Spacer()
                    if model.isSubmitting { ProgressView().controlSize(.small) }
                    Button(model.isSubmitting ? L("Unlocking…") : L("Unlock")) { model.submit() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.isSubmitting || model.password.isEmpty)
                        .accessibilityIdentifier("macUnlockSubmit")
                }
            }.padding(24)
        }
        .frame(idealWidth: 440, idealHeight: 420)
        .interactiveDismissDisabled(model.isSubmitting)
        .onAppear { passwordFocused = true }
    }
}
