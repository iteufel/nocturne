import NocturneKit
import SwiftUI

struct ClientOnboardingView: View {
    /// `true` hands off to the existing camera/pairing flow after onboarding has closed.
    let finish: (Bool) -> Void
    @State private var step = 0

    private let titles = [L("Your Mac.\nA little more freedom."), L("A whole workspace.\nIn your hands."), L("One scan.\nMake the connection.")]
    private let subtitles = [
        L("Bring your Mac to your iPhone or iPad. Pick up your desktop from a different seat."),
        L("Your desktop is just the beginning. Keep your favorite ways to work close by."),
        L("Open Nocturne on your Mac. Your devices will be together in a moment.")
    ]

    var body: some View {
        NocturneOnboarding(product: "Nocturne", steps: [L("Welcome"), L("Your workspace"), L("Connect your Mac")], step: step,
            scene: step == 0 ? .welcome : step == 1 ? .workspace : .pairing,
            title: titles[step], subtitle: subtitles[step],
            action: step == 2 ? L("Add my Mac") : L("Continue"),
            advance: { if step < 2 { step += 1 } else { finish(true) } },
            back: { step = max(0, step - 1) }, skip: { finish(false) }) {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 15) {
                        OnboardingFeature(icon: "display", title: L("Same Mac. A new place."), detail: L("Your apps, your desktop, your familiar setup."))
                        OnboardingFeature(icon: "hand.draw", title: L("Touch, type, or play"), detail: L("Use touch or connect a keyboard, mouse, or controller."))
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 15) {
                        OnboardingFeature(icon: "macwindow", title: L("Give your apps room"), detail: L("Open individual Mac app windows on iPad."))
                        OnboardingFeature(icon: "terminal", title: L("Leave a shell running"), detail: L("Return to your Mac’s terminal sessions when you reconnect."))
                        OnboardingFeature(icon: "folder", title: L("Bring your files along"), detail: L("Access your shared folder, even in the Files app."))
                    }
                default:
                    VStack(alignment: .leading, spacing: 17) {
                        OnboardingFeature(icon: "1.circle", title: L("Start on your Mac"), detail: L("Install and open Nocturne. Enabled services start automatically."))
                        OnboardingFeature(icon: "2.circle", title: L("Choose Pair a device"), detail: L("Your Mac shows a private, single-use QR code."))
                        OnboardingFeature(icon: "3.circle", title: L("Scan from this device"), detail: L("Choose Scan QR code on the next screen. Allow camera and local network access when asked."))
                        Link(destination: URL(string: "https://github.com/iteufel/nocturne/releases")!) {
                            Label(L("Get Nocturne for Mac"), systemImage: "arrow.up.right")
                                .font(.system(size: 12, weight: .medium))
                        }.padding(.top, 3)
                    }
                }
            }
    }
}
