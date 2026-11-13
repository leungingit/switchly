import SwiftUI

/// 所有序列共用时间刻度和纵轴，每条线保持一种颜色，不平滑或推断缺失数据。
struct PluginLineChart: View {
    let items: [PluginBarItem]
    var series: [PluginLineSeries] = []
    var label: String? = nil
    @Environment(\.locale) private var locale

    private var plots: [(label: String?, items: [PluginBarItem])] {
        [(label, items)] + series.map { (Optional($0.label), $0.items) }
    }
    private var maximum: Double {
        max(1, plots.flatMap(\.items).map(\.value).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if label != nil {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    ForEach(Array(plots.enumerated()), id: \.offset) { index, plot in
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Capsule().fill(DesignTokens.Plugin.sequenceColor(at: index))
                                .frame(width: DesignTokens.Spacing.md, height: DesignTokens.Plugin.chartLineWidth)
                                .accessibilityHidden(true)
                            Text(plot.label ?? "").font(.caption).lineLimit(2)
                                .help(plot.label ?? "")
                        }
                    }
                }
            }
            Text(duration(maximum)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            GeometryReader { geometry in
                ZStack {
                    Path { path in
                        for fraction in [0.0, 0.5, 1.0] {
                            let y = geometry.size.height * fraction
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                    }
                    .stroke(Color.secondary.opacity(DesignTokens.Glass.groupBorderOpacity),
                            style: StrokeStyle(lineWidth: DesignTokens.hairline, dash: [4, 4]))
                    ForEach(Array(plots.enumerated()), id: \.offset) { index, plot in
                        let color = DesignTokens.Plugin.sequenceColor(at: index)
                        let points = plot.items.enumerated().map { offset, item in
                            CGPoint(x: items.count <= 1 ? geometry.size.width / 2
                                    : geometry.size.width * CGFloat(offset) / CGFloat(items.count - 1),
                                    y: geometry.size.height * CGFloat(1 - item.value / maximum))
                        }
                        if index == 0, let first = points.first, let last = points.last {
                            Path { path in
                                path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                                path.addLines(points)
                                path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                                path.closeSubpath()
                            }
                            .fill(color.opacity(DesignTokens.Plugin.chartAreaOpacity))
                        }
                        Path { $0.addLines(points) }
                            .stroke(color, style: StrokeStyle(lineWidth: DesignTokens.Plugin.chartLineWidth,
                                                             lineCap: .round, lineJoin: .round,
                                                             dash: index == 0 && !series.isEmpty ? [4, 4] : []))
                        ForEach(Array(plot.items.enumerated()), id: \.offset) { offset, item in
                            Circle().fill(color)
                                .frame(width: DesignTokens.Plugin.chartPointSize, height: DesignTokens.Plugin.chartPointSize)
                                .position(points[offset])
                                .help([plot.label, item.label, duration(item.value)].compactMap { $0 }.joined(separator: " · "))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text([plot.label, item.label].compactMap { $0 }.joined(separator: " · ")))
                                .accessibilityValue(Text(duration(item.value)))
                        }
                    }
                }
            }
            .frame(height: DesignTokens.Plugin.chartHeight)
            HStack {
                Text(items.first?.label ?? "")
                Spacer()
                if items.count > 2 { Text(items[items.count / 2].label); Spacer() }
                if items.count > 1 { Text(items.last?.label ?? "") }
            }
            .font(.caption2.monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(DesignTokens.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
    }

    private func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian); calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 3; formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0"
    }
}
