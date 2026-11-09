import NocturneKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared visual language for the two halves of a Nocturne connection.
enum OnboardingScene: Int {
    case welcome, workspace, permissions, pairing
}

struct NocturneOnboarding<Content: View>: View {
    let product: String
    let steps: [String]
    let step: Int
    let scene: OnboardingScene
    let title: String
    let subtitle: String
    let action: String
    var busy = false
    let advance: () -> Void
    let back: () -> Void
    let skip: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    MoonMark(size: 30)
                    Text(product.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(2)
                    Spacer()
                    Button(L("Set up later"), action: skip).buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(MoonStyle.secondary)
                        .frame(minHeight: 44).accessibilityIdentifier("onboardingSkip")
                }.padding(.horizontal, wide ? 36 : 24).padding(.top, 16)

                ScrollView {
                    Group {
                        if wide {
                            HStack(spacing: 36) {
                                artwork.frame(maxWidth: .infinity)
                                page(wide: true).frame(maxWidth: 390)
                            }.padding(.horizontal, 44).frame(minHeight: max(0, geometry.size.height - 190))
                        } else {
                            VStack(spacing: 12) {
                                artwork.frame(height: geometry.size.height < 650 ? 150 : scene == .welcome ? 245 : 185)
                                page(wide: false)
                            }.padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 24)
                        }
                    }.frame(maxWidth: 1100).frame(maxWidth: .infinity)
                }.scrollBounceBehavior(.basedOnSize)
                    // Each step starts at the top, even after reading a longer page with large text.
                    .id(step)
                    .transition(reduceMotion ? .identity : .opacity)

                footer(wide: wide)
            }.animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)
        }
        .foregroundStyle(MoonStyle.silver)
        .background { NocturneBackdrop() }
    }

    private var artwork: some View {
        ConnectionArtwork(scene: scene)
            .frame(minHeight: 170, idealHeight: 360, maxHeight: 390)
            .accessibilityHidden(true)
    }

    private func page(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text(steps[step].uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.5).foregroundStyle(MoonStyle.accent)
                Text(title).font(.system(size: wide ? titleSize * 40 / 34 : titleSize, weight: .semibold, design: .rounded))
                    .tracking(-1.4).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingTitle")
                Text(subtitle).font(.system(size: bodySize)).foregroundStyle(MoonStyle.secondary)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 12)),
            removal: .opacity.combined(with: .offset(y: -8))))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)
        .padding(.vertical, 12)
    }

    private func footer(wide: Bool) -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule().fill(index <= step ? MoonStyle.accent : MoonStyle.accent.opacity(0.15))
                        .frame(width: index == step ? 30 : 8, height: 4)
                }
                Spacer()
                Text(L("%@ of %@", "\(step + 1)", "\(steps.count)")).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MoonStyle.secondary)
            }.accessibilityElement(children: .ignore).accessibilityLabel(L("Step %@ of %@: %@", "\(step + 1)", "\(steps.count)", "\(steps[step])"))
            HStack(spacing: 16) {
                if step > 0 {
                    Button(L("Back"), action: back).buttonStyle(.plain).font(.system(size: 14))
                        .frame(minHeight: 44).accessibilityIdentifier("onboardingBack")
                } else {
                    Label(L("Made for your Mac"), systemImage: "moon").font(.system(size: 11))
                        .foregroundStyle(MoonStyle.secondary)
                }
                Spacer(minLength: 4)
                Button(action: advance) {
                    HStack(spacing: 10) {
                        if busy { ProgressView().controlSize(.small).tint(MoonStyle.ink) }
                        Text(action)
                        if !busy { Image(systemName: "arrow.right") }
                    }.font(.system(size: 14, weight: .semibold)).foregroundStyle(MoonStyle.ink).padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("onboardingContinue")
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: step)
        .padding(.horizontal, wide ? 36 : 26).padding(.top, 18).padding(.bottom, 22)
        .frame(maxWidth: 1100).frame(maxWidth: .infinity)
        .background(MoonStyle.ink.opacity(0.94))
    }
}

/// Device silhouettes carry the same desktop from Mac to iPad. All artwork is native vector UI.
struct ConnectionArtwork: View {
    let scene: OnboardingScene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let drift = CGFloat(sin(time * 0.8))
            GeometryReader { geometry in
                let width = min(geometry.size.width * 0.92, geometry.size.height * 1.25, 440)
                ZStack {
                    Ellipse().fill(MoonStyle.accent.opacity(0.13)).blur(radius: 30)
                        .frame(width: width * 0.85, height: width * 0.5)
                    Ellipse().stroke(MoonStyle.accent.opacity(0.12), lineWidth: 1)
                        .frame(width: width * 0.98, height: width * 0.57)
                        .rotationEffect(.degrees(-24))
                    Ellipse().stroke(MoonStyle.accent.opacity(0.07), lineWidth: 1)
                        .frame(width: width * 1.1, height: width * 0.72)
                        .rotationEffect(.degrees(-24))
                    mac(width: width * 0.71)
                        .rotationEffect(.degrees(-5)).offset(x: -width * 0.095, y: -width * 0.07 + drift * 3)
                    // A small traveling signal makes the relationship between both devices tangible.
                    ForEach(0..<3) { index in
                        let progress = (time * 0.25 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().fill(MoonStyle.mint.opacity(reduceMotion ? 0.6 : sin(progress * .pi) * 0.85))
                            .frame(width: 4, height: 4)
                            .offset(x: width * (-0.12 + progress * 0.44), y: width * (0.03 + progress * 0.28))
                    }
                    tablet(width: width * 0.53)
                        .rotationEffect(.degrees(7)).offset(x: width * 0.21, y: width * 0.17 - drift * 4)
                    if scene == .permissions {
                        badge("lock.shield.fill", label: L("You're in control"))
                            .offset(x: -width * 0.16, y: width * 0.35)
                    } else {
                        badge(scene == .pairing ? "qrcode.viewfinder" : "sparkle", label: scene == .pairing ? L("One scan. Together.") : L("Your Mac, within reach"))
                            .offset(x: -width * 0.09, y: width * 0.38)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: scene)
            .allowsHitTesting(false)
            // The iOS client uses UIHostingController rather than a SwiftUI App/Scene.
            // Observe the application lifecycle directly so its timeline also resumes there.
            #if os(macOS)
            .onAppear { active = NSApp.isActive }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in active = false }
            #else
            .onAppear { active = UIApplication.shared.applicationState == .active }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in active = false }
            #endif
    }

    private func mac(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            wallpaper(width: width, tablet: false)
                .padding(7).background(Color(red: 0.16, green: 0.17, blue: 0.23), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2), lineWidth: 1))
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.43), Color(white: 0.68)], startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.14, height: width * 0.075)
            Capsule().fill(Color(white: 0.65)).frame(width: width * 0.37, height: 4)
        }.shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.13), radius: 18, y: 14)
    }

    private func tablet(width: CGFloat) -> some View {
        wallpaper(width: width, tablet: true).padding(6)
            .background(Color(red: 0.12, green: 0.13, blue: 0.18), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(white: 0.55), lineWidth: 1.3))
            .overlay(alignment: .bottom) { Capsule().fill(.white.opacity(0.7)).frame(width: width * 0.2, height: 2).padding(.bottom, 10) }
            .shadow(color: .black.opacity(0.2), radius: 18, y: 12)
    }

    private func wallpaper(width: CGFloat, tablet: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.14, green: 0.15, blue: 0.3), Color(red: 0.32, green: 0.28, blue: 0.53), Color(red: 0.62, green: 0.53, blue: 0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(LinearGradient(colors: [Color(red: 0.94, green: 0.91, blue: 1), Color(red: 0.6, green: 0.63, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: width * 0.29, height: width * 0.29).offset(x: width * 0.19, y: -width * 0.055)
            Ellipse().fill(Color(red: 0.22, green: 0.23, blue: 0.39)).frame(width: width * 1.5, height: width * 0.5)
                .rotationEffect(.degrees(-18)).offset(y: width * 0.32)
            Ellipse().fill(Color(red: 0.13, green: 0.15, blue: 0.27)).frame(width: width * 1.6, height: width * 0.45)
                .rotationEffect(.degrees(15)).offset(y: width * 0.4)
            if scene == .workspace {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.5)).frame(width: 3, height: 3) } }
                    Text("~ / workspace").font(.system(size: width * 0.045, design: .monospaced))
                    Text("❯ _").font(.system(size: width * 0.07, design: .monospaced)).foregroundStyle(Color(red: 0.55, green: 0.87, blue: 0.73))
                }.foregroundStyle(.white.opacity(0.8)).padding(width * 0.06).frame(width: width * 0.64, alignment: .leading)
                    .background(Color(red: 0.08, green: 0.1, blue: 0.17).opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                    .rotationEffect(.degrees(3)).offset(x: -width * 0.06, y: width * 0.03)
            }
            if scene == .pairing && !tablet {
                Image(systemName: "qrcode").resizable().interpolation(.none).scaledToFit()
                    .foregroundStyle(Color(red: 0.1, green: 0.12, blue: 0.2)).padding(9)
                    .frame(width: width * 0.36, height: width * 0.36).background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            if scene == .pairing && tablet {
                Image(systemName: "viewfinder").font(.system(size: width * 0.32, weight: .ultraLight)).foregroundStyle(.white.opacity(0.9))
            }
            if scene == .permissions {
                Image(systemName: "lock.shield").font(.system(size: width * 0.24, weight: .ultraLight)).foregroundStyle(.white)
            }
            VStack {
                HStack { Circle().fill(.white.opacity(0.7)).frame(width: 3, height: 3); Spacer(); Capsule().fill(.white.opacity(0.4)).frame(width: width * 0.12, height: 2) }
                    .padding(.horizontal, 8).padding(.top, 5)
                Spacer()
                if scene == .welcome {
                    HStack(spacing: 4) {
                        ForEach(["safari", "folder.fill", "terminal.fill", "gearshape.fill"], id: \.self) { icon in
                            Image(systemName: icon).font(.system(size: width * 0.035)).foregroundStyle(.white.opacity(0.9))
                                .frame(width: width * 0.07, height: width * 0.07).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }.padding(4).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5)).padding(.bottom, 7)
                }
            }
        }.frame(width: width, height: width * (tablet ? 0.67 : 0.6)).clipShape(RoundedRectangle(cornerRadius: tablet ? 10 : 6))
    }

    private func badge(_ icon: String, label: String) -> some View {
        Label(label, systemImage: icon).font(.system(size: 10, weight: .medium))
            .foregroundStyle(MoonStyle.accent).padding(.horizontal, 12).padding(.vertical, 9)
            .background(MoonStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(MoonStyle.accent.opacity(0.12), lineWidth: 1))
    }
}

struct OnboardingFeature: View {
    let icon: String
    let title: String
    let detail: String
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 12
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(MoonStyle.accent)
                .frame(width: 38, height: 38).background(MoonStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: titleSize, weight: .semibold))
                Text(detail).font(.system(size: detailSize)).foregroundStyle(MoonStyle.secondary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
