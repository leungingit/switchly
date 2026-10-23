import AppKit

/// 面板隐藏后聚焦失败时仍提供可见反馈，不把应用激活误报成切窗成功。
enum WindowSwitchFeedback {
    @MainActor
    static func presentFailure(language: AppLanguage) {
        let alert = NSAlert()
        alert.messageText = language.localizedString("Unable to focus this window")
        alert.informativeText = language.localizedString("The window may have closed, or macOS did not switch to its desktop. You can try selecting it in Mission Control.")
        alert.addButton(withTitle: language.localizedString("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
