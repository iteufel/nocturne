import SwiftUI
import AppKit
import ApplicationServices

struct ServerOnboardingView: View {
    @ObservedObject var model: ServerModel
    let finish: (Bool) -> Void
    @State private var step = 0
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var inputAllowed = AXIsProcessTrusted()
    private let titles = ["Your Mac.\nOn every screen.", "A little permission.\nA lot of possibility.", "Ready when\nyou are."]
    private let subtitles = [
        "Make room for a different way to work and play. Your Mac does the heavy lifting. Your iPhone or iPad comes along.",
        "macOS keeps you in control. Allow screen recording to stream, and Accessibility to control your Mac.",
        "Start your server, then pair your iPhone or iPad. One QR code brings your workspace together."
    ]

    var body: some View {
        NocturneOnboarding(product: "Nocturne Server", steps: ["Welcome", "Mac permissions", "Pair your device"], step: step,
            scene: step == 0 ? .welcome : step == 1 ? .permissions : .pairing,
            title: titles[step], subtitle: subtitles[step],
            action: step == 2 ? (model.starting ? "Starting server…" : model.running ? "Pair a device" : "Start & pair a device") : "Continue",
            busy: model.starting,
            advance: { if step < 2 { step += 1 } else { finish(true) } },
            back: { step = max(0, step - 1) }, skip: { finish(false) }) {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingFeature(icon: "display", title: "Your desktop, beautifully close", detail: "Stream your Mac or open individual app windows on iPad.")
                        OnboardingFeature(icon: "lock.shield", title: "You choose what to share", detail: "Pair the devices you trust. Terminal and files stay off until you enable them.")
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 12) {
                        permission(icon: "rectangle.inset.filled.and.person.filled", title: "Screen & audio", detail: "Share your screen and its sound.", allowed: screenAllowed) {
                            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                            model.openPrivacy("ScreenCapture")
                        }
                        permission(icon: "cursorarrow", title: "Keyboard & mouse", detail: "Control your Mac from your device.", allowed: inputAllowed) {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            if !AXIsProcessTrustedWithOptions(options) { model.openPrivacy("Accessibility") }
                        }
                        Text("Enable Nocturne Server in System Settings. If macOS asks you to quit and reopen, do that before starting. You can also finish permissions later.")
                            .font(.system(size: 11)).foregroundStyle(MoonStyle.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                default:
                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingFeature(icon: "iphone.and.arrow.forward", title: "Open Nocturne on your device", detail: "Choose Add host, then Scan QR code.")
                        OnboardingFeature(icon: "qrcode.viewfinder", title: "Scan the code on this Mac", detail: "The next screen starts your server and shows its pairing code.")
                        Label("Keep both devices on the same network for your first connection.", systemImage: "wifi")
                            .font(.system(size: 12)).foregroundStyle(MoonStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !screenAllowed || !inputAllowed {
                            Button("Review Mac permissions", systemImage: "exclamationmark.circle") { step = 1 }
                                .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
            .task(id: step) {
                guard step == 1 else { return }
                while !Task.isCancelled {
                    refreshPermissions()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
    }

    private func permission(icon: String, title: String, detail: String, allowed: Bool, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingFeature(icon: icon, title: title, detail: detail)
            HStack {
                Label(allowed ? "Allowed" : "Needs permission", systemImage: allowed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(allowed ? MoonStyle.mint : MoonStyle.secondary)
                Spacer()
                Button(allowed ? "Review" : "Open settings", action: open)
                    .buttonStyle(NocturneGlassButtonStyle()).controlSize(.small)
            }
        }.padding(14).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        inputAllowed = AXIsProcessTrusted()
    }
}
