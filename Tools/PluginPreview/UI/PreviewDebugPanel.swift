import AppKit
import SwiftUI

// MARK: - 视图

/// 预览 app 最右侧的可收起调试面板：控制台 / JSON / 渲染日志。
struct PreviewDebugPanelView: View {
    @ObservedObject var model: PreviewDebugModel

    /// JSON 树视图状态由面板持有：切换标签页时不丢失，JSON 内容变化时按默认两层重置。
    @State private var jsonExpandedIDs: Set<Int> = []
    @State private var jsonSelectedRowID: Int?

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.tab {
            case .console: consoleBody
            case .json: jsonBody
            case .renders: rendersBody
            }
        }
        .frame(width: PreviewDebugModel.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: DesignTokens.hairline)
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Picker("", selection: $model.tab) {
                ForEach(PreviewDebugModel.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button { model.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Clear")
                .accessibilityLabel(Text("Clear"))
            Button { model.setVisible(false) } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .help("Hide debug panel")
                .accessibilityLabel(Text("Hide debug panel"))
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, PreviewLauncherLayout.windowTitlebarInset)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    private var consoleBody: some View {
        Group {
            if model.console.isEmpty {
                placeholder("No console output yet. `console.log` from the plugin appears here after the next render.")
            } else {
                DebugTextView(text: consoleText, autoscroll: true)
            }
        }
    }

    private var consoleText: String {
        model.console.map { "\(Self.timeFormat.string(from: $0.time)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
    }

    private var jsonBody: some View {
        Group {
            if model.jsonRows.isEmpty {
                if model.prettyJSON.isEmpty {
                    placeholder("No render output yet.")
                } else {
                    // 输出不是 JSON 时无法建树，保持原有的纯文本降级展示。
                    DebugTextView(text: model.prettyJSON, autoscroll: false)
                }
            } else {
                PreviewJSONTreeView(rows: model.jsonRows,
                                    expandedIDs: $jsonExpandedIDs,
                                    selectedRowID: $jsonSelectedRowID)
                    .onAppear(perform: syncJSONTreeState)
                    .onReceive(model.$jsonRows) { _ in syncJSONTreeState() }
            }
        }
    }

    /// 节点 id 是数组下标，JSON 内容变化后旧下标会指向别的节点，
    /// 因此每次重建树都恢复默认的前两层展开并清空选中项。
    private func syncJSONTreeState() {
        jsonExpandedIDs = PreviewDebugModel.defaultExpandedIDs(in: model.jsonRows)
        jsonSelectedRowID = nil
    }

    private var rendersBody: some View {
        Group {
            if model.renders.isEmpty {
                placeholder("No renders yet.")
            } else {
                DebugTextView(text: rendersText, autoscroll: true)
            }
        }
    }

    private var rendersText: String {
        model.renders.map { entry in
            let head = "#\(entry.id) \(Self.timeFormat.string(from: entry.time))"
            if let failure = entry.failure { return "\(head)  FAILED \(failure)  \(Int(entry.durationMs)) ms" }
            let scene = entry.sceneKey.map { "key=\($0)" + (entry.sceneEpoch.map { String(format: " epoch=%.1f", $0) } ?? "") } ?? "no scene"
            return "\(head)  \(String(format: "%.0f", entry.durationMs)) ms  \(entry.bytes) B  \(scene)"
        }.joined(separator: "\n")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 面板展开按钮：浮在右栏右上角，面板收起时显示。
struct PreviewDebugToggleButton: View {
    @ObservedObject var model: PreviewDebugModel

    var body: some View {
        Button { model.setVisible(true) } label: {
            Image(systemName: "ladybug")
                .padding(6)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help("Show debug panel")
        .accessibilityLabel(Text("Show debug panel"))
    }
}

/// 只读等宽文本：NSTextView 对数十万字符的 JSON 比 SwiftUI Text 流畅得多，且可选中复制。
struct DebugTextView: NSViewRepresentable {
    let text: String
    let autoscroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.isAutomaticQuoteSubstitutionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        // 用户已滚离底部时，不把视图拽回底部。
        let clip = scroll.contentView.bounds
        let atBottom = clip.maxY >= (scroll.documentView?.frame.height ?? 0) - 24
        let offset = clip.origin
        view.string = text
        if autoscroll && atBottom { view.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: offset) }
    }
}
