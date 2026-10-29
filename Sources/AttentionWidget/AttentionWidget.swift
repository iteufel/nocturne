import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NocturneAttentionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AttentionAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label("Nocturne needs your attention", systemImage: "hand.raised")
                Text("Request \(context.attributes.request.id.prefix(8))").font(.caption)
                if context.isStale { Text("Open Nocturne to refresh").font(.caption) }
                else { actions(context) }
            }.padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "hand.raised") }
                DynamicIslandExpandedRegion(.center) { Text("Nocturne · request \(context.attributes.request.id.prefix(8))") }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale { Text("Open Nocturne to refresh") }
                    else { actions(context) }
                }
            } compactLeading: { Image(systemName: "hand.raised") }
              compactTrailing: { Image(systemName: "exclamationmark.bubble") }
              minimal: { Image(systemName: "hand.raised") }
        }
    }
    @ViewBuilder private func actions(_ context: ActivityViewContext<AttentionAttributes>) -> some View {
        HStack {
            if context.state.canDeny {
                Button("Deny", intent: AttentionDecisionIntent(context.attributes.request, allow: false))
            }
            if context.state.canAllow {
                Button("Allow once", intent: AttentionDecisionIntent(context.attributes.request, allow: true))
            }
            if !context.state.canAllow && !context.state.canDeny { Text("Review in Nocturne") }
        }.buttonStyle(.bordered)
    }
}
