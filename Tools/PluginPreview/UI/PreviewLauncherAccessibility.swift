import AppKit
import SwiftUI

/// 启动器按钮的可访问性桥接。
///
/// SwiftUI 的 `Button` 在 macOS 上只把 `accessibilityLabel` 暴露为
/// `AXAttributedDescription`，并不生成 `AXDescription` 或 `AXTitle`；
/// 系统级 AX（osascript / VoiceOver / 辅助工具）因此读不到标题。
/// 这里用一个不参与布局的 `NSButton` 作为 accessibility representation：
/// 它提供 `AXTitle` 与 `AXDescription`，并把 AXPress 转发回原动作。
struct LauncherAccessibleButtonRepresentation: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        button.setAccessibilityLabel(title)
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        nsView.setAccessibilityLabel(title)
        nsView.isEnabled = isEnabled
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func press() {
            action()
        }
    }
}

extension View {
    /// 让 SwiftUI 按钮同时拥有 AXTitle/AXDescription。标签必须与可见文案一致。
    func launcherAccessibleButton(_ label: String,
                                  isEnabled: Bool = true,
                                  action: @escaping () -> Void) -> some View {
        modifier(LauncherAccessibleButtonModifier(label: label, isEnabled: isEnabled, action: action))
    }
}

private struct LauncherAccessibleButtonModifier: ViewModifier {
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityRepresentation {
                LauncherAccessibleButtonRepresentation(title: label, isEnabled: isEnabled, action: action)
            }
    }
}
