//
//  StatisticsChartView.swift
//  Switchly
//
//  Hand-drawn chart for the statistics panel: macOS 12 cannot use Swift Charts,
//  and every tick / point / bar here is a pure function so it can be unit
//  tested headless.
//
//  The view deliberately computes nothing: it receives already-aggregated
//  values and only maps them to geometry.
//

import SwiftUI

struct StatisticsChartInsets: Equatable {
    var top: CGFloat = 12
    var leading: CGFloat = 44
    var bottom: CGFloat = 22
    var trailing: CGFloat = 12

    static let standard = StatisticsChartInsets()
}

enum StatisticsChartStyle {
    case line
    case bar
}

/// What the Y axis counts. Drives only the tick labels.
enum StatisticsChartValueFormat {
    case count
    case seconds

    func axisLabel(_ value: Double, axisMax: Double) -> String {
        switch self {
        case .count:
            return String(Int(value.rounded()))
        case .seconds:
            // Sub-minute windows read better in seconds; longer ones in minutes.
            if axisMax < 60 {
                return String(Int(value.rounded()))
            }
            return String(Int((value / 60).rounded()))
        }
    }

    func unitSuffix(axisMax: Double) -> String {
        switch self {
        case .count: return ""
        case .seconds: return axisMax < 60 ? "s" : "m"
        }
    }
}

struct StatisticsSeries: Identifiable {
    let id: String
    let title: String
    let color: Color
    let values: [Double]
    let isDashed: Bool
}

/// Pure geometry. Kept out of the view so the tests can pin it down.
enum StatisticsChartMath {
    /// 1 / 2 / 5 x 10^n.
    static func niceStep(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 1 }
        let exponent = (log10(raw)).rounded(.down)
        let magnitude = pow(10.0, exponent)
        let normalized = raw / magnitude
        let nice: Double
        if normalized <= 1 {
            nice = 1
        } else if normalized <= 2 {
            nice = 2
        } else if normalized <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * magnitude
    }

    /// Integer ticks from zero up to (at least) `maxValue`.
    ///
    /// Steps stay >= 1: the plotted values are counts and whole seconds, and a
    /// fractional step would round into duplicate axis labels (0, 1, 1, 2, 2).
    /// A flat-zero series must still produce a drawable axis.
    static func yTicks(maxValue: Double, targetCount: Int = 4) -> [Double] {
        guard maxValue.isFinite, maxValue > 0 else { return [0, 1] }
        let step = max(1, niceStep(maxValue / Double(max(1, targetCount))))
        guard step.isFinite, step > 0 else { return [0, max(1, maxValue)] }
        var ticks: [Double] = [0]
        var value = step
        while value < maxValue + step * 0.5, ticks.count < 12 {
            ticks.append(value)
            value += step
        }
        if ticks.count < 2 { ticks.append(max(step, maxValue)) }
        return ticks
    }

    /// Y ticks whose labels fit the plot height without colliding, walked
    /// from the axis maximum (which anchors the scale) downward, keeping
    /// labels at least `minSpacing` points apart. The short savings chart
    /// (plot ≈ 18 pt tall) otherwise stacks four 9 pt labels into a jumble.
    static func readableTicks(ticks: [Double],
                              axisMax: Double,
                              plotHeight: CGFloat,
                              minSpacing: CGFloat = 11) -> [Double] {
        guard plotHeight > 0, !ticks.isEmpty else { return ticks }
        let safeMax = max(axisMax, 1)
        func y(_ value: Double) -> CGFloat {
            plotHeight * CGFloat(1 - min(max(value, 0), safeMax) / safeMax)
        }
        var kept: [Double] = [ticks.last!]
        var lastY = y(ticks.last!)
        for tick in ticks.reversed().dropFirst() {
            let currentY = y(tick)
            if currentY - lastY >= minSpacing {
                kept.insert(tick, at: 0)
                lastY = currentY
            }
        }
        return kept
    }

    static func plotRect(size: CGSize, insets: StatisticsChartInsets = .standard) -> CGRect {
        let width = max(1, size.width - insets.leading - insets.trailing)
        let height = max(1, size.height - insets.top - insets.bottom)
        return CGRect(x: insets.leading, y: insets.top, width: width, height: height)
    }

    static func axisMaximum(_ ticks: [Double]) -> Double {
        max(ticks.last ?? 1, 1)
    }

    static func points(values: [Double],
                       size: CGSize,
                       axisMax: Double,
                       insets: StatisticsChartInsets = .standard) -> [CGPoint] {
        let plot = plotRect(size: size, insets: insets)
        guard !values.isEmpty else { return [] }
        let safeMax = max(axisMax, 1)
        return values.enumerated().map { index, value in
            let ratio: CGFloat
            if values.count == 1 {
                ratio = 0.5
            } else {
                ratio = CGFloat(index) / CGFloat(values.count - 1)
            }
            let x = plot.minX + plot.width * ratio
            let clamped = max(0, value)
            let y = plot.maxY - plot.height * CGFloat(min(clamped, safeMax) / safeMax)
            return CGPoint(x: x, y: y)
        }
    }

    static func bars(values: [Double],
                     size: CGSize,
                     axisMax: Double,
                     insets: StatisticsChartInsets = .standard) -> [CGRect] {
        let plot = plotRect(size: size, insets: insets)
        guard !values.isEmpty else { return [] }
        let safeMax = max(axisMax, 1)
        let slot = plot.width / CGFloat(values.count)
        let barWidth = max(2, slot * 0.6)
        return values.enumerated().map { index, value in
            let clamped = max(0, value)
            let height = plot.height * CGFloat(min(clamped, safeMax) / safeMax)
            let x = plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2
            return CGRect(x: x, y: plot.maxY - height, width: barWidth, height: height)
        }
    }

    /// How many buckets to skip between X labels so text cannot overlap.
    static func labelStride(bucketCount: Int, plotWidth: CGFloat, labelWidth: CGFloat) -> Int {
        guard bucketCount > 1, plotWidth > 0, labelWidth > 0 else { return 1 }
        let slot = plotWidth / CGFloat(bucketCount)
        guard slot > 0 else { return 1 }
        return max(1, Int(ceil(labelWidth / slot)))
    }

    /// Always keep the first and last label: they anchor the time range.
    static func labelIndices(bucketCount: Int, stride: Int) -> [Int] {
        guard bucketCount > 0 else { return [] }
        let step = max(1, stride)
        var indices = Swift.stride(from: 0, to: bucketCount, by: step).map { $0 }
        if let last = indices.last, last != bucketCount - 1 {
            // Drop the second-to-last if the final label would collide with it.
            if bucketCount - 1 - last < step, indices.count > 1 {
                indices.removeLast()
            }
            indices.append(bucketCount - 1)
        }
        return indices
    }

    /// Bucket index under a cursor x: the nearest plotted point for lines,
    /// the slot for bars. Uses the same geometry as `points` / `bars`, so
    /// the hover guide always sits on drawn data. Nil when there is nothing
    /// to point at.
    static func hoveredIndex(x: CGFloat, plot: CGRect, count: Int, style: StatisticsChartStyle) -> Int? {
        guard count > 0, plot.width > 0 else { return nil }
        switch style {
        case .line:
            guard count > 1 else { return 0 }
            let ratio = (x - plot.minX) / plot.width
            return min(max(Int((ratio * CGFloat(count - 1)).rounded()), 0), count - 1)
        case .bar:
            let slot = plot.width / CGFloat(count)
            return min(max(Int(((x - plot.minX) / slot).rounded(.down)), 0), count - 1)
        }
    }

    /// X of a bucket's anchor: the plotted point for lines, the slot center
    /// for bars -- the hover guide and tooltip align to it.
    static func dataX(index: Int, plot: CGRect, count: Int, style: StatisticsChartStyle) -> CGFloat {
        switch style {
        case .line:
            guard count > 1 else { return plot.midX }
            return plot.minX + plot.width * CGFloat(index) / CGFloat(count - 1)
        case .bar:
            let slot = plot.width / CGFloat(max(count, 1))
            return plot.minX + slot * CGFloat(index) + slot / 2
        }
    }
}

struct StatisticsChartView: View {
    let labels: [String]
    let series: [StatisticsSeries]
    let style: StatisticsChartStyle
    let valueFormat: StatisticsChartValueFormat
    var insets: StatisticsChartInsets = .standard
    /// The savings chart shares its X dates with the frequency chart right
    /// above it, so it draws bars only -- repeating the dates would double
    /// the labels and eat plot height the 810 pt window does not have.
    var showsXLabels: Bool = true

    /// Cursor x while it is over the chart, nil when it leaves. Drives the
    /// hover guide and the value card; nil keeps the chart static.
    @State private var hoverX: CGFloat?

    init(labels: [String],
         series: [StatisticsSeries],
         style: StatisticsChartStyle,
         valueFormat: StatisticsChartValueFormat,
         insets: StatisticsChartInsets = .standard,
         showsXLabels: Bool = true,
         previewHoverX: CGFloat? = nil) {
        self.labels = labels
        self.series = series
        self.style = style
        self.valueFormat = valueFormat
        self.insets = insets
        self.showsXLabels = showsXLabels
        // Seeds the hover state for SwiftUI previews and the snapshot tests:
        // State reads the initial value on the first render, which is exactly
        // the frame an offscreen render captures. Live interaction goes
        // through ChartHoverTracker instead.
        _hoverX = State(initialValue: previewHoverX)
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(context: &context, size: size)
            }
            .overlay(ChartHoverTracker { hoverX = $0 })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var axisMax: Double {
        let ticks = StatisticsChartMath.yTicks(maxValue: maxValue)
        return StatisticsChartMath.axisMaximum(ticks)
    }

    private var maxValue: Double {
        series.flatMap(\.values).max() ?? 0
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let plot = StatisticsChartMath.plotRect(size: size, insets: insets)
        let ticks = StatisticsChartMath.yTicks(maxValue: maxValue)
        let maxValueOnAxis = StatisticsChartMath.axisMaximum(ticks)
        let labeledTicks = Set(StatisticsChartMath.readableTicks(ticks: ticks,
                                                                 axisMax: maxValueOnAxis,
                                                                 plotHeight: plot.height))
        let gridColor = Color(nsColor: .separatorColor).opacity(0.5)
        let axisColor = Color(nsColor: .tertiaryLabelColor)

        // Grid + Y labels (labels only where they fit without colliding)
        for tick in ticks {
            let ratio = CGFloat(min(tick, maxValueOnAxis) / maxValueOnAxis)
            let y = plot.maxY - plot.height * ratio
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: DesignTokens.hairline)

            guard labeledTicks.contains(tick) else { continue }
            let text = Text(valueFormat.axisLabel(tick, axisMax: maxValueOnAxis) + valueFormat.unitSuffix(axisMax: maxValueOnAxis))
                .font(.system(size: 9))
                .foregroundColor(axisColor)
            context.draw(text, at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }

        // Axes
        var axis = Path()
        axis.move(to: CGPoint(x: plot.minX, y: plot.minY))
        axis.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        axis.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(axis, with: .color(axisColor), lineWidth: DesignTokens.hairline)

        switch style {
        case .line:
            for item in series {
                let points = StatisticsChartMath.points(values: item.values,
                                                        size: size,
                                                        axisMax: maxValueOnAxis)
                guard points.count > 1 else { continue }
                var path = Path()
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round,
                                         dash: item.isDashed ? [4, 3] : [])
                context.stroke(path, with: .color(item.color), style: stroke)

                // Dots only while they cannot smear into a line.
                if points.count <= 30 {
                    for point in points {
                        let dot = CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)
                        context.fill(Path(ellipseIn: dot), with: .color(item.color))
                    }
                }
            }
        case .bar:
            let values = series.first?.values ?? []
            let rects = StatisticsChartMath.bars(values: values,
                                                 size: size,
                                                 axisMax: maxValueOnAxis)
            let color = series.first?.color ?? .accentColor
            for rect in rects {
                context.fill(Path(rect), with: .color(color))
            }
        }

        // X labels
        guard showsXLabels, !labels.isEmpty else { return }
        let stride = StatisticsChartMath.labelStride(bucketCount: labels.count,
                                                     plotWidth: plot.width,
                                                     labelWidth: 34)
        for index in StatisticsChartMath.labelIndices(bucketCount: labels.count, stride: stride) {
            guard index < labels.count else { continue }
            let x = labels.count == 1
                ? plot.midX
                : plot.minX + plot.width * CGFloat(index) / CGFloat(labels.count - 1)
            let anchor: UnitPoint = index == 0 ? .topLeading : (index == labels.count - 1 ? .topTrailing : .top)
            let text = Text(labels[index])
                .font(.system(size: 9))
                .foregroundColor(axisColor)
            context.draw(text, at: CGPoint(x: x, y: plot.maxY + 6), anchor: anchor)
        }

        // Hover: guide at the nearest bucket plus a compact value card.
        if let hoverX,
           let index = StatisticsChartMath.hoveredIndex(x: hoverX, plot: plot,
                                                        count: labels.count, style: style) {
            let anchorX = StatisticsChartMath.dataX(index: index, plot: plot,
                                                    count: labels.count, style: style)
            var guide = Path()
            guide.move(to: CGPoint(x: anchorX, y: plot.minY))
            guide.addLine(to: CGPoint(x: anchorX, y: plot.maxY))
            context.stroke(guide, with: .color(gridColor), lineWidth: DesignTokens.hairline)
            drawTooltip(context: &context, index: index, anchorX: anchorX, plot: plot, size: size)
        }
    }

    /// Compact value card pinned to the plot top, flipping to the left of
    /// the guide when it would run off the right edge and pulled back down
    /// when the chart is too short for it (the savings chart). Drawn in the
    /// Canvas so it shares the chart's coordinate space and the view stays a
    /// leaf -- no extra layout pass per hover.
    private func drawTooltip(context: inout GraphicsContext,
                             index: Int,
                             anchorX: CGFloat,
                             plot: CGRect,
                             size: CGSize) {
        let titleFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let rowFont = NSFont.systemFont(ofSize: 10)
        let dateWidth = (labels[index] as NSString).size(withAttributes: [.font: titleFont]).width
        var rowLines: [String] = []
        var rowWidths: [CGFloat] = []
        for item in series {
            let value = index < item.values.count ? item.values[index] : 0
            let line = item.title + "  " + formattedValue(value)
            rowLines.append(line)
            rowWidths.append((line as NSString).size(withAttributes: [.font: rowFont]).width)
        }

        let rowHeight: CGFloat = 15
        let swatchWidth: CGFloat = 10
        let leadingPad: CGFloat = 8
        let textWidth = max(dateWidth, rowWidths.max() ?? 0)
        let cardWidth = leadingPad + swatchWidth + 6 + textWidth + 10
        let cardHeight = 6 + CGFloat(rowLines.count + 1) * rowHeight + 4

        var cardX = anchorX + 12
        if cardX + cardWidth > size.width - 4 {
            cardX = anchorX - 12 - cardWidth
        }
        cardX = max(2, cardX)
        var cardY = plot.minY + 2
        if cardY + cardHeight > size.height - 2 {
            cardY = max(2, size.height - 2 - cardHeight)
        }

        let cardRect = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        let card = Path(roundedRect: cardRect, cornerRadius: 6)
        context.fill(card, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        context.stroke(card, with: .color(Color(nsColor: .separatorColor)), lineWidth: DesignTokens.hairline)

        context.draw(Text(labels[index])
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: cardX + leadingPad, y: cardY + 6 + rowHeight / 2),
                     anchor: .leading)
        for (row, line) in rowLines.enumerated() {
            let centerY = cardY + 6 + CGFloat(row + 1) * rowHeight + rowHeight / 2
            let color = series[row].color
            let swatchRect = CGRect(x: cardX + leadingPad,
                                    y: centerY - 1.5,
                                    width: swatchWidth,
                                    height: 3)
            context.fill(Path(roundedRect: swatchRect, cornerRadius: 1.5), with: .color(color))
            context.draw(Text(line).font(.system(size: 10)).foregroundColor(.primary),
                         at: CGPoint(x: cardX + leadingPad + swatchWidth + 6, y: centerY),
                         anchor: .leading)
        }
    }

    /// Same conventions as the axis labels -- whole counts; seconds below a
    /// minute, minutes above -- so the card never contradicts the axis.
    private func formattedValue(_ value: Double) -> String {
        switch valueFormat {
        case .count:
            return String(Int(value.rounded()))
        case .seconds:
            let total = Int(value.rounded())
            if total < 60 { return "\(total)s" }
            return "\(total / 60)m \(total % 60)s"
        }
    }

    private var accessibilitySummary: String {
        series.map { item in
            let total = Int(item.values.reduce(0, +).rounded())
            return "\(item.title): \(total)"
        }
        .joined(separator: ", ")
    }
}

/// Reports the cursor x while it is over the chart, nil on exit.
/// NSTrackingArea rather than onContinuousHover: the deployment target is
/// macOS 12, where that modifier does not exist yet.
private struct ChartHoverTracker: NSViewRepresentable {
    var onMove: (CGFloat?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onMove: onMove)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: (CGFloat?) -> Void

        init(onMove: @escaping (CGFloat?) -> Void) {
            self.onMove = onMove
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Hover must work on a plain mouse move, without a click first.
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self,
                                           userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            onMove(convert(event.locationInWindow, from: nil).x)
        }

        override func mouseExited(with event: NSEvent) {
            onMove(nil)
        }
    }
}

/// Clickable legend. At least one series always stays visible.
struct StatisticsLegendView: View {
    let series: [StatisticsSeries]
    let isVisible: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ForEach(series) { item in
                Button {
                    toggle(item.id)
                } label: {
                    HStack(spacing: 5) {
                        Capsule()
                            .fill(item.color)
                            .opacity(isVisible(item.id) ? 1 : 0.25)
                            .frame(width: 14, height: 3)
                        Text(item.title)
                            .font(.system(size: 11))
                            .foregroundColor(isVisible(item.id) ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
    }
}
