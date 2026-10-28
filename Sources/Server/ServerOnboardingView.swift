import NocturneKit
import SwiftUI
import AppKit
import ApplicationServices

struct ServerOnboardingView: View {
    @ObservedObject var model: ServerModel
    let finish: (Bool) -> Void
    @State private var step = 0
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var inputAllowed = AXIsProcessTrusted()
    private let titles = [L("Your Mac.\nOn every screen."), L("A little permission.\nA lot of possibility."), L("Ready when\nyou are.")]
    private let subtitles = [
        L("Make room for a different way to work and play. Your Mac does the heavy lifting. Your iPhone or iPad comes along."),
        L("macOS keeps you in control. Allow screen recording to stream, and Accessibility to control your Mac."),
        L("Your server starts enabled services automatically. Pair your iPhone or iPad to bring your workspace together.")
    ]

    var body: some View {
        NocturneOnboarding(product: "Nocturne", steps: [L("Welcome"), L("Mac permissions"), L("Pair your device")], step: step,
            scene: step == 0 ? .welcome : step == 1 ? .permissions : .pairing,
            title: titles[step], subtitle: subtitles[step],
            action: step == 2 ? (model.starting ? L("Starting server…") : model.running ? L("Pair a device") : L("Start & pair a device")) : L("Continue"),
            busy: model.starting,
            advance: { if step < 2 { step += 1 } else { finish(true) } },
            back: { step = max(0, step - 1) }, skip: { finish(false) }) {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingFeature(icon: "display", title: L("Your desktop, beautifully close"), detail: L("Stream your Mac or open individual app windows on iPad."))
                        OnboardingFeature(icon: "lock.shield", title: L("You choose what to share"), detail: L("Pair the devices you trust. Terminal and files stay off until you enable them."))
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 12) {
                        permission(icon: "rectangle.inset.filled.and.person.filled", title: L("Screen & audio"), detail: L("Share your screen and its sound."), allowed: screenAllowed) {
                            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                            model.openPrivacy("ScreenCapture")
                        }
                        permission(icon: "cursorarrow", title: L("Keyboard & mouse"), detail: L("Control your Mac from your device."), allowed: inputAllowed) {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            if !AXIsProcessTrustedWithOptions(options) { model.openPrivacy(L("Accessibility")) }
                        }
                        Text(L("Enable Nocturne in System Settings. If macOS asks you to quit and reopen, do that before starting. You can also finish permissions later."))
                            .font(.system(size: 11)).foregroundStyle(MoonStyle.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                default:
                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingFeature(icon: "iphone.and.arrow.forward", title: L("Open Nocturne on your device"), detail: L("Choose Add host, then Scan QR code."))
                        OnboardingFeature(icon: "qrcode.viewfinder", title: L("Scan the code on this Mac"), detail: L("The next screen shows this Mac’s private pairing code."))
                        Label(L("Keep both devices on the same network for your first connection."), systemImage: "wifi")
                            .font(.system(size: 12)).foregroundStyle(MoonStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !screenAllowed || !inputAllowed {
                            Button(L("Review Mac permissions"), systemImage: "exclamationmark.circle") { step = 1 }
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
                Label(allowed ? L("Allowed") : L("Needs permission"), systemImage: allowed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(allowed ? MoonStyle.mint : MoonStyle.secondary)
                Spacer()
                Button(allowed ? L("Review") : L("Open settings"), action: open)
                    .buttonStyle(NocturneGlassButtonStyle()).controlSize(.small)
            }
        }.padding(14).background(MoonStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        inputAllowed = AXIsProcessTrusted()
    }
}
