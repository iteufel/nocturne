import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum NocturneAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum MoonStyle {
    static let ink = adaptive(0xF4F5FA, 0x10121B)
    static let surface = adaptive(0xFFFFFF, 0x232630)
    static let elevated = adaptive(0xE9EAF3, 0x303440)
    static let accent = adaptive(0x6552C8, 0xBEBAFF)
    static let silver = Color.primary
    static let secondary = Color.secondary
    static let mint = adaptive(0x238267, 0x8CDDBB)
    static let terminalInk = Color(red: 0.045, green: 0.055, blue: 0.085)
    static let terminalText = Color(red: 0.88, green: 0.91, blue: 0.98)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #endif
    }
}

/// Color stays in the content layer so the system glass can pick it up naturally.
struct NocturneBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            MoonStyle.ink
            if !reduceTransparency {
                RadialGradient(colors: [MoonStyle.accent.opacity(scheme == .dark ? 0.17 : 0.15), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color.cyan.opacity(scheme == .dark ? 0.06 : 0.08), .clear], center: .topTrailing, startRadius: 0, endRadius: 500)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Keep adjacent glass controls in one rendering container on current systems.
struct NocturneGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}

extension View {
    @ViewBuilder func nocturneGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

struct MoonMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: "moon.fill")
            .font(.system(size: size * 0.57, weight: .medium))
            .rotationEffect(.degrees(-24))
            .foregroundStyle(MoonStyle.accent)
            .frame(width: size, height: size)
            .background(MoonStyle.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

/// A small piece of native vector artwork, shared by the client and server.
struct LunarArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(MoonStyle.accent.opacity(0.07)).blur(radius: 35).frame(width: size * 0.8)
                Ellipse().stroke(MoonStyle.accent.opacity(0.16), lineWidth: 1)
                    .frame(width: size * 0.96, height: size * 0.37).rotationEffect(.degrees(-28))
                Circle().fill(RadialGradient(colors: [.white, Color(red: 0.71, green: 0.73, blue: 0.95), Color(red: 0.31, green: 0.34, blue: 0.59)], center: .topLeading, startRadius: 0, endRadius: size * 0.7))
                    .frame(width: size * 0.58, height: size * 0.58)
                    .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1).frame(width: size * 0.58))
                    .shadow(color: MoonStyle.accent.opacity(0.12), radius: 30)
                Circle().fill(MoonStyle.silver).frame(width: 5, height: 5).offset(x: size * 0.39, y: -size * 0.20)
                Circle().fill(MoonStyle.accent.opacity(0.4)).frame(width: 3, height: 3).offset(x: -size * 0.36, y: size * 0.2)
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let label: String
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(active ? MoonStyle.mint : MoonStyle.secondary).frame(width: 5, height: 5)
            Text(label).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(active ? MoonStyle.mint : MoonStyle.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((active ? MoonStyle.mint : MoonStyle.secondary).opacity(0.08), in: Capsule())
    }
}

struct MoonPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(MoonStyle.surface.opacity(reduceTransparency ? 1 : 0.78), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(scheme == .dark ? 0.08 : 0.85), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.08 : 0.035), radius: 18, y: 8)
    }
}

struct SectionCaption: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Spacer()
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(MoonStyle.secondary) }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(MoonStyle.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(MoonStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
}

struct PrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(configuration).buttonStyle(.glassProminent).controlSize(.large).buttonBorderShape(.capsule)
        } else {
            Button(configuration).buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
        }
    }
}

struct NocturneGlassButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(configuration).buttonStyle(.glass).buttonBorderShape(.capsule)
                #if os(macOS)
                .tint(nil)
                #endif
        } else {
            Button(configuration).buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}
