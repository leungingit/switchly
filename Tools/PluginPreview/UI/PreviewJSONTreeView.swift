import AppKit
import SwiftUI

/// JSON 树视图：语法高亮 + 可展开折叠节点。
///
/// 大 JSON（可达上万节点）只渲染当前可见行：折叠节点的整段子树由
/// `visibleRowIndices` 跳过，`LazyVStack` 只创建滚到视口附近的行。
/// 颜色全部来自系统语义色，随浅色/深色外观自动切换。
struct PreviewJSONTreeView: View {
    let rows: [PreviewDebugModel.JSONTreeRow]
    @Binding var expandedIDs: Set<Int>
    @Binding var selectedRowID: Int?

    private enum Palette {
        static let key = Color(nsColor: .systemPurple)
        static let string = Color(nsColor: .systemGreen)
        static let number = Color(nsColor: .systemOrange)
        static let boolean = Color(nsColor: .systemBlue)
        static let neutral = Color(nsColor: .secondaryLabelColor)
    }

    private var visibleIndices: [Int] {
        PreviewDebugModel.visibleRowIndices(rows, expandedIDs: expandedIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleIndices, id: \.self) { index in
                        rowView(rows[index])
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var toolbar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button("Expand all") { expandedIDs = Set(rows.lazy.filter(\.isExpandable).map(\.id)) }
            Button("Collapse all") { expandedIDs = [] }
            Spacer(minLength: 0)
            Button { copySelected() } label: { Image(systemName: "doc.on.doc") }
                .disabled(selectedRowID == nil)
                .help("Copy selected value")
                .accessibilityLabel(Text("Copy selected value"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func rowView(_ row: PreviewDebugModel.JSONTreeRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            disclosure(for: row)
            label(for: row)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, indent(for: row))
        .padding(.trailing, DesignTokens.Spacing.md)
        .padding(.vertical, 1)
        .background(selectedRowID == row.id ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedRowID = row.id }
        .contextMenu {
            Button("Copy value") { copy(row) }
            if let key = row.key {
                Button("Copy key") { copyToPasteboard(key) }
            }
        }
    }

    @ViewBuilder
    private func disclosure(for row: PreviewDebugModel.JSONTreeRow) -> some View {
        if row.isExpandable {
            Button { toggle(row) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Palette.neutral)
                    .rotationEffect(.degrees(expandedIDs.contains(row.id) ? 90 : 0))
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(expandedIDs.contains(row.id) ? "Collapse node" : "Expand node"))
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    private func label(for row: PreviewDebugModel.JSONTreeRow) -> Text {
        var text = Text("")
        if let key = row.key {
            text = text + Text("\"\(key)\"").foregroundColor(Palette.key)
            text = text + Text(": ").foregroundColor(Palette.neutral)
        }
        return text + Text(row.text).foregroundColor(color(for: row.kind))
    }

    private func color(for kind: PreviewDebugModel.JSONTreeKind) -> Color {
        switch kind {
        case .object, .array: return Palette.neutral
        case .string: return Palette.string
        case .number: return Palette.number
        case .boolean: return Palette.boolean
        case .null: return Palette.neutral
        }
    }

    /// 缩进限制在 16 层内：更深的节点不再递增缩进，避免内容被挤出 380pt 面板。
    private func indent(for row: PreviewDebugModel.JSONTreeRow) -> CGFloat {
        DesignTokens.Spacing.xs + CGFloat(min(row.depth, 16)) * DesignTokens.Spacing.md
    }

    private func toggle(_ row: PreviewDebugModel.JSONTreeRow) {
        if expandedIDs.contains(row.id) {
            expandedIDs.remove(row.id)
        } else {
            expandedIDs.insert(row.id)
        }
    }

    private func copy(_ row: PreviewDebugModel.JSONTreeRow) {
        guard let text = PreviewDebugModel.copyText(rows, at: row.id) else { return }
        copyToPasteboard(text)
    }

    private func copySelected() {
        guard let id = selectedRowID, rows.indices.contains(id) else { return }
        copy(rows[id])
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
