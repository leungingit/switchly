import AppKit
import CoreGraphics

final class Delegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var timer: Timer?
    private var label: NSTextField!
    private var phase = ""
    private var mode = "idle"
    private var started = 0.0
    private var activeSince: Double?
    private var maximumContinuous = 0.0
    private var lastActivation = -Double.infinity
    private var activations = 0
    private var lastTrace = -Double.infinity
    private var complete = false
    private var requiredContinuous = 45.0
    private var root: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    private var letter: String { Bundle.main.bundleIdentifier!.hasSuffix("a") ? "A" : "B" }
    private var command: URL { root.appendingPathComponent("control-\(letter).json") }
    private var status: URL { root.appendingPathComponent("status-\(letter).json") }
    private var uptime: Double { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "退出验收窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu; NSApp.mainMenu = menu
        let visible = (NSScreen.screens.last ?? NSScreen.main!).visibleFrame
        window = NSWindow(contentRect: NSRect(x: visible.maxX-540,y:visible.minY+40,width:500,height:300),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "活动连续验收 \(letter)"; window.isReleasedWhenClosed = false
        window.backgroundColor = letter == "A" ? .systemTeal : .systemIndigo
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString:"活动连续验收 \(letter)"); title.font = .systemFont(ofSize:34,weight:.bold); title.textColor = .white
        label = NSTextField(labelWithString:"等待自动验收指令"); label.font = .systemFont(ofSize:17); label.textColor = .white; label.alignment = .center
        let button = NSButton(title:"停止自动前台",target:self,action:#selector(stop)); button.bezelStyle = .rounded
        stack.addArrangedSubview(title); stack.addArrangedSubview(label); stack.addArrangedSubview(button)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:window.contentView!.centerXAnchor),stack.centerYAnchor.constraint(equalTo:window.contentView!.centerYAnchor)])
        window.orderFrontRegardless()
        timer = Timer(timeInterval:0.25,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!,forMode:.common)
        tick()
    }
    @objc private func stop() { mode = "idle"; complete = true; label.stringValue = "自动前台已停止"; writeStatus() }
    private func tick() {
        let mono = uptime
        if let data = try? Data(contentsOf: command), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let id = value["phase"] as? String, id != phase {
            phase = id; mode = value["mode"] as? String ?? "idle"; requiredContinuous = min(120,max(30,value["seconds"] as? Double ?? 45)); started = mono; activeSince = nil; maximumContinuous = 0; complete = false; activations = 0; lastActivation = -.infinity
        }
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        if active {
            if activeSince == nil { activeSince = mono }
            maximumContinuous = max(maximumContinuous,mono-activeSince!)
        } else { activeSince = nil }
        if mode == "hold" && !complete {
            if maximumContinuous >= requiredContinuous { complete = true }
            else if mono-started >= 150 { mode = "timeout"; complete = true }
            else if !active && mono-lastActivation >= 3 && activations < 20 {
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                lastActivation = mono; activations += 1
            }
            label.stringValue = "\(phase)\n连续前台 \(Int(maximumContinuous)) / \(Int(requiredContinuous)) 秒"
        }
        if mono-lastTrace >= 1 { writeStatus(); lastTrace = mono }
    }
    private func writeStatus() {
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        let value: [String:Any] = ["phase":phase,"mode":mode,"completed":complete,"wall":Date().timeIntervalSince1970,"uptime":uptime,"active":current,"continuous":activeSince.map { uptime-$0 } ?? 0,"maximumContinuous":maximumContinuous,"activations":activations,"requiredContinuous":requiredContinuous,"idleSeconds":CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)]
        guard let data = try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) else { return }
        try? data.write(to:status,options:.atomic)
        let trace = root.appendingPathComponent("trace-\(letter).jsonl")
        if !FileManager.default.fileExists(atPath:trace.path) { FileManager.default.createFile(atPath:trace.path,contents:nil) }
        if let handle = try? FileHandle(forWritingTo:trace) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf:data+Data([10])) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let delegate = Delegate(); NSApplication.shared.delegate = delegate; NSApplication.shared.run()
