import SwiftUI
import NocturneKit

struct ChatTranscript: View {
    @ObservedObject var model: ChatWorkspaceModel
    @State private var following = true
    @State private var jump = 0
    private var groups: [[ChatMessage]] {
        model.messages.reduce(into: [[ChatMessage]]()) { groups, message in
            if message.role == .tool, groups.last?.last?.role == .tool { groups[groups.count - 1].append(message) }
            else { groups.append([message]) }
        }
    }
    var body: some View {
        ChatTranscriptScrollView(conversationID: model.selected?.id ?? "", firstMessageID: model.messages.first?.id,
                                 jump: jump, canLoadEarlier: model.hasOlderMessages && !model.loadingOlder && !model.loading && !model.responding && !model.voiceEngaged,
                                 loadEarlier: { if let selected = model.selected { Task { await model.open(selected, older: true) } } },
                                 followingChanged: { if following != $0 { following = $0 } }) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(groups, id: \.first!.id) { group in
                    if group.first?.role == .tool { ChatToolGroup(messages: group) }
                    else if let message = group.first { ChatTranscriptMessage(message: message, provider: model.provider?.name ?? L("Agent")) }
                }
                if model.responding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(model.permissions.isEmpty ? L("Working") : L("Waiting for your decision"))
                        if let start = model.respondingSince { Text(start, style: .relative).monospacedDigit() }
                    }.font(.caption).foregroundStyle(ChatStyle.secondary)
                }
            }.padding(24).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .overlay(alignment: .top) {
            if model.loadingOlder { ProgressView().controlSize(.small).padding(10).modifier(ChatGlass()).padding(8).accessibilityLabel(L("Loading earlier messages")) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !following {
                Button { jump += 1 } label: {
                    Image(systemName: "arrow.down").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44).modifier(ChatGlass())
                }.buttonStyle(.plain).accessibilityLabel(L("Jump to latest message")).accessibilityIdentifier("chatJumpToLatest").padding(16)
            }
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
                        Label(message.text.split(separator: "\n").first.map(String.init) ?? L("Tool activity"), systemImage: "terminal")
                            .lineLimit(1).font(.caption)
                    }
                }
            }.padding(.top, 12)
        } label: {
            Label(LCount("Ran %d tool actions", messages.count), systemImage: "hammer")
                .font(.subheadline)
        }.foregroundStyle(ChatStyle.secondary).tint(ChatStyle.secondary)
    }
}

private struct ChatTranscriptMessage: View {
    let message: ChatMessage
    let provider: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = ChatMessagePresentation.summary(message) {
                DisclosureGroup {
                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 12)
                } label: { Label(summary, systemImage: "waveform.path.ecg").font(.subheadline).lineLimit(3) }
                    .foregroundStyle(ChatStyle.secondary).tint(ChatStyle.secondary).padding(14)
                    .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            } else if message.role == .user {
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
                    Text(message.role == .assistant ? provider : L("Activity")).font(.caption2)
                    Button { UIPasteboard.general.string = message.text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(L("Copy response"))
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
                            Text(lines.first ?? L("Code")).font(.caption2).foregroundStyle(ChatStyle.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(L("Copy code"))
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
