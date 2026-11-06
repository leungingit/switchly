import AppKit
import SwiftUI

/// 启动器共享的小型展示组件与格式化。仅承载样式和文案，不持有草稿状态。
struct LauncherControlLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }
}

/// 透明标题栏下的拖动区：SwiftUI 的 ScrollView 会吞掉鼠标事件，窗口无法被拖动，
/// 这里放一块声明 `mouseDownCanMoveWindow` 的 AppKit 视图，覆盖标题栏高度。
struct LauncherWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

extension View {
    /// 与 `PluginPreviewView` 一致的控制卡片：语义底色 + 共享材质与细边框。
    func launcherCard(material: CrystalMaterial,
                      fill: Color = Color(nsColor: .controlBackgroundColor).opacity(0.72)) -> some View {
        padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(
                fill: fill,
                cornerRadius: DesignTokens.Radius.control,
                material: material,
                showsBorder: true
            )
    }
}

/// manifest 设置与槽位名的本地化格式化，供默认只读区与自定义编辑器共用。
enum PreviewLauncherFormat {
    static func settingTitle(_ spec: PluginSettingSpec, language: AppLanguage) -> String {
        spec.title[language.rawValue] ?? spec.title["en"] ?? spec.key
    }

    static func optionTitle(_ option: PluginSettingOption, language: AppLanguage) -> String {
        option.title[language.rawValue] ?? option.title["en"] ?? option.value
    }

    static func settingText(_ value: PluginSettingValue, language: AppLanguage) -> String {
        switch value {
        case .bool(let bool): return bool ? language.localizedString("On") : language.localizedString("Off")
        case .number(let number):
            guard number.isFinite else { return "0" }
            if number.rounded() == number, abs(number) <= 9_007_199_254_740_992 {
                return "\(Int(number))"
            }
            return "\(number)"
        case .string(let string): return string
        }
    }

    static func slotName(_ slot: PluginSlot, language: AppLanguage) -> String {
        switch slot {
        case .center: return language.localizedString("Center")
        case .bottomBar: return language.localizedString("Bottom bar")
        case .topTrailing: return language.localizedString("Top trailing")
        case .titleAccessory: return language.localizedString("Title accessory")
        }
    }
}
