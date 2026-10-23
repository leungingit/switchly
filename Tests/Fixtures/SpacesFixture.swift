import AppKit

/// 仅创建受控空白窗口；桌面移动通过系统调度中心手动完成。
final class SpacesFixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "退出验证应用", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        for index in 1...2 {
            let window = NSWindow(contentRect: NSRect(x: 200 + index * 60, y: 200 + index * 40, width: 620, height: 360),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Switchly 验证窗口 \(index)"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "跨桌面验证 · 窗口 \(index)")
            label.font = .systemFont(ofSize: 30)
            label.frame = NSRect(x: 60, y: 150, width: 500, height: 50)
            window.contentView?.addSubview(label)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SpacesFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = SpacesFixtureDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
