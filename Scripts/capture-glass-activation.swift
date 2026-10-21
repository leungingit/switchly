// Opt-in native desktop diagnostic, not a product screenshot or unit test.
// swift Scripts/capture-glass-activation.swift --capture /tmp/switchly-glass-activation
import AppKit

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--capture" else {
    fputs("Usage: swift Scripts/capture-glass-activation.swift --capture OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}
guard #available(macOS 26.0, *) else { fatalError("Requires macOS 26 native glass") }
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let frame = NSRect(x: 160, y: 170, width: 386, height: 317)
let backdrop = NSWindow(contentRect: frame.insetBy(dx: -20, dy: -20),
                        styleMask: .titled, backing: .buffered, defer: false)
let text = NSTextView(frame: backdrop.contentLayoutRect)
text.string = String(repeating: "Glass backdrop sample 0123456789\n", count: 35)
text.font = .systemFont(ofSize: 18)
text.backgroundColor = .white
text.textColor = .black
backdrop.contentView = text
backdrop.level = .floating
// Keep the same optical view and geometry; only the key window changes.
let window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView],
                      backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.isOpaque = false
window.backgroundColor = .clear
window.appearance = NSAppearance(named: .aqua)
window.level = .popUpMenu
let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
glass.style = .clear
glass.cornerRadius = 28
window.contentView = glass
backdrop.orderFront(nil)
window.orderFront(nil)
app.activate(ignoringOtherApps: true)
func capture(_ name: String, expectedKey: Bool) {
    guard window.isKeyWindow == expectedKey else {
        fputs("Invalid focus state for \(name); no capture accepted\n", stderr)
        exit(1)
    }
    guard let screen = window.screen else { exit(1) }
    let actual = window.frame
    let rect = "\(Int(actual.minX)),\(Int(screen.frame.maxY - actual.maxY)),\(Int(actual.width)),\(Int(actual.height))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R", rect, directory.appendingPathComponent("clear-\(name).png").path]
    do { try process.run() } catch { fatalError("Capture failed: \(error)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(1) }
    print("\(name): key=\(window.isKeyWindow), style=\(glass.style.rawValue), frame=\(actual)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    backdrop.makeKeyAndOrderFront(nil)
    window.orderFront(nil)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    capture("inactive", expectedKey: false)
    window.makeKeyAndOrderFront(nil)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
    capture("active", expectedKey: true)
    app.terminate(nil)
}
app.run()
