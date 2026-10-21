import SwiftUI

struct ClientOnboardingView: View {
    /// `true` hands off to the pairing flow after onboarding has closed.
    let finish: (Bool) -> Void
    @State private var step = 0

    private let titles = ["Your Mac.\nA little more freedom.", "A whole workspace.\nIn your hands.", "Your devices.\nTogether in a moment."]
    private let subtitles = [
        "Bring your Mac to your iPhone or iPad. Pick up your desktop from a different seat.",
        "Your desktop is just the beginning. Keep your favorite ways to work close by.",
        "Open Nocturne Server on your Mac. Your devices will be together in a moment."
    ]

    var body: some View {
        NocturneOnboarding(product: "Nocturne", steps: ["Welcome", "Your workspace", "Connect your Mac"], step: step,
            scene: step == 0 ? .welcome : step == 1 ? .workspace : .pairing,
            title: titles[step], subtitle: subtitles[step],
            action: step == 2 ? "Add my Mac" : "Continue",
            advance: { if step < 2 { step += 1 } else { finish(true) } },
            back: { step = max(0, step - 1) }, skip: { finish(false) }) {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 15) {
                        OnboardingFeature(icon: "display", title: "Same Mac. A new place.", detail: "Your apps, your desktop, your familiar setup.")
                        OnboardingFeature(icon: "hand.draw", title: "Touch, type, or play", detail: "Use touch or connect a keyboard, mouse, or controller.")
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 15) {
                        OnboardingFeature(icon: "macwindow", title: "Give your apps room", detail: "Open individual Mac app windows on iPad.")
                        OnboardingFeature(icon: "terminal", title: "Leave a shell running", detail: "Return to your Mac’s terminal sessions when you reconnect.")
                        OnboardingFeature(icon: "folder", title: "Bring your files along", detail: "Access your shared folder, even in the Files app.")
                    }
                default:
                    VStack(alignment: .leading, spacing: 17) {
                        OnboardingFeature(icon: "1.circle", title: "Start on your Mac", detail: "Install and open Nocturne Server. Enabled services start automatically.")
                        OnboardingFeature(icon: "2.circle", title: "Choose Pair a device", detail: "Your Mac shows a private, single-use QR code and a Copy pairing link button.")
                        OnboardingFeature(icon: "3.circle", title: "Scan or paste a link", detail: "Scan the QR code, or send the pairing link to this device and paste it on the next screen. Allow local network access when asked.")
                        Link(destination: URL(string: "https://github.com/iteufel/nocturne/releases")!) {
                            Label("Get Nocturne Server for Mac", systemImage: "arrow.up.right")
                                .font(.system(size: 12, weight: .medium))
                        }.padding(.top, 3)
                    }
                }
            }
    }
}
