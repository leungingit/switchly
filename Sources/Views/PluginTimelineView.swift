import SwiftUI

/// 各条目的轴线覆盖整行高度，截图或长文本展开后仍能连接下一节点。
struct PluginTimelineView: View {
    let items: [PluginTimelineItem]
    let content: (PluginUINode) -> AnyView
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                        Text(formatted(item.timestamp, time: true))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(formatted(item.timestamp, time: false))
                            .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: DesignTokens.Plugin.timelineTimeWidth, alignment: .trailing)
                    Color.clear.frame(width: DesignTokens.Plugin.timelineRailWidth)
                        .accessibilityHidden(true)
                    content(item.content).frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, index == items.count - 1 ? 0 : DesignTokens.Spacing.lg)
                .background(GeometryReader { geometry in
                    let x = DesignTokens.Plugin.timelineTimeWidth + DesignTokens.Spacing.md
                        + DesignTokens.Plugin.timelineRailWidth / 2
                    let y = DesignTokens.Spacing.sm
                    ZStack(alignment: .topLeading) {
                        if index < items.count - 1 {
                            Path { path in
                                path.move(to: CGPoint(x: x, y: y))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height + y))
                            }
                            .stroke(LinearGradient(colors: [DesignTokens.Plugin.sequenceColor(at: index),
                                                            DesignTokens.Plugin.sequenceColor(at: index + 1)],
                                                   startPoint: .top, endPoint: .bottom),
                                    lineWidth: DesignTokens.Plugin.timelineLineWidth)
                        }
                        Circle().fill(DesignTokens.Plugin.sequenceColor(at: index))
                            .frame(width: DesignTokens.Plugin.timelineMarkerSize,
                                   height: DesignTokens.Plugin.timelineMarkerSize)
                            .position(x: x, y: y)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func formatted(_ timestamp: Double, time: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        if time { formatter.dateFormat = "HH:mm:ss" }
        else { formatter.dateStyle = .short; formatter.timeStyle = .none }
        let value = formatter.string(from: Date(timeIntervalSince1970: timestamp))
        return value.isEmpty ? "—" : value
    }
}
