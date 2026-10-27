import SwiftUI
import NocturneKit

struct ChatTranscript: View {
    @ObservedObject var model: ChatWorkspaceModel
    @State private var following = true
    private var groups: [[ChatMessage]] {
        model.messages.reduce(into: [[ChatMessage]]()) { groups, message in
            if message.role == .tool, groups.last?.last?.role == .tool { groups[groups.count - 1].append(message) }
            else { groups.append([message]) }
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if model.hasOlderMessages, let selected = model.selected {
                        Button("Load earlier messages") { Task { await model.open(selected, older: true) } }.font(.caption).disabled(model.loading)
                    }
                    ForEach(groups, id: \.first!.id) { group in
                        if group.first?.role == .tool { ChatToolGroup(messages: group) }
                        else if let message = group.first { ChatTranscriptMessage(message: message, provider: model.provider?.name ?? "Agent") }
                    }
                    if model.responding {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text(model.permissions.isEmpty ? "Working" : "Waiting for your decision")
                                if let start = model.respondingSince { Text(start, style: .relative).monospacedDigit() }
                            }.font(.caption).foregroundStyle(ChatStyle.secondary)
                        }
                    }
                    Color.clear.frame(height: 2).id("latest")
                }.padding(.horizontal, 24).padding(.vertical, 24).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.last?.text) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: model.messages.count) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                Button { following = true; proxy.scrollTo("latest", anchor: .bottom) } label: { Image(systemName: "arrow.down").padding(12).modifier(ChatGlass()) }
                    .buttonStyle(.plain).accessibilityLabel("Jump to latest message").padding(12)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in following = false })
        }
    }
}

private struct ChatToolGroup: View {
    let messages: [ChatMessage]
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    DisclosureGroup {
                        Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
                    } label: {
                        Label(String(message.text.split(separator: "\n").first ?? "Tool activity"), systemImage: "terminal")
                            .lineLimit(1).font(.caption)
                    }
                }
            }.padding(.top, 12)
        } label: {
            Label(messages.count == 1 ? "Used a tool" : "Ran \(messages.count) tool actions", systemImage: "hammer")
                .font(.subheadline)
        }.foregroundStyle(ChatStyle.secondary).tint(ChatStyle.secondary)
    }
}

private struct ChatTranscriptMessage: View {
    let message: ChatMessage
    let provider: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 30)
                    if let summary = PullRequestAgentPrompt.summary(message.text) {
                        DisclosureGroup(summary) { Text(message.text).font(.caption).textSelection(.enabled).padding(.top, 12) }
                            .padding(16).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                    } else { Text(message.text).textSelection(.enabled).padding(16).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 20)) }
                }
            } else {
                ChatMarkdown(text: message.text)
                HStack(spacing: 16) {
                    Text(message.role == .assistant ? provider : "Activity").font(.caption2)
                    Button { UIPasteboard.general.string = message.text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy response")
                }.font(.caption).foregroundStyle(ChatStyle.secondary).buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatMarkdown: View {
    let text: String
    private var blocks: [(Int, String)] { text.components(separatedBy: "```").enumerated().map { ($0.offset, $0.element) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks, id: \.0) { index, block in
                if index % 2 == 1 {
                    let lines = block.components(separatedBy: "\n")
                    let code = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : block
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(lines.first ?? "Code").font(.caption2).foregroundStyle(ChatStyle.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy code")
                        }.font(.caption).buttonStyle(.plain)
                        ScrollView(.horizontal) { Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.padding(16).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                } else if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(Array(block.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        if paragraph.hasPrefix("# ") || paragraph.hasPrefix("## ") || paragraph.hasPrefix("### ") {
                            Text(String(paragraph.drop(while: { $0 == "#" || $0 == " " }))).font(.title3.weight(.semibold)).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                        } else {
                            Text((try? AttributedString(markdown: paragraph, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(paragraph))
                                .font(.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
