import SwiftUI

enum ChatStyle {
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.035, alpha: 1) : UIColor(white: 0.98, alpha: 1) })
    static let sidebar = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.105, alpha: 1) : UIColor(white: 0.93, alpha: 1) })
    static let selected = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.88, alpha: 1) })
    static let secondary = Color(uiColor: .secondaryLabel)
    static let blue = Color(red: 0, green: 0.56, blue: 1)
    static let green = Color(red: 0, green: 0.78, blue: 0.6)
    static let purple = Color(red: 0.65, green: 0.45, blue: 1)
    static func projectName(_ directory: String) -> String { directory.isEmpty ? "your project" : URL(fileURLWithPath: directory).lastPathComponent }
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func prColor(_ state: String) -> Color { ["merged", "completed"].contains(state) ? purple : ["closed", "abandoned"].contains(state) ? .red : green }
}

struct ChatCircleButton: View {
    let title: String
    let symbol: String
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).frame(width: 44, height: 44)
                .foregroundStyle(selected ? ChatStyle.blue : Color.primary)
                .background(selected ? ChatStyle.canvas : .clear, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

struct ChatGlass: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
    }
}

struct ChatEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(ChatStyle.secondary)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(ChatStyle.secondary).multilineTextAlignment(.center).lineSpacing(4)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChatProjectMark: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(2)).uppercased()).font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.85)).frame(width: 22, height: 22)
            .background(ChatStyle.purple.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
    }
}
