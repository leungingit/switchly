import Foundation

@main
struct PackageWatcherTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-watch-test-" + UUID().uuidString)
        let package = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = #"{"id":"com.example.plugin","name":{"en":"Example"},"version":"1","apiVersion":1,"matches":["com.example.app"],"permissions":[],"entry":"main.js"}"#
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        let source = package.appendingPathComponent("main.js")
        try Data("one".utf8).write(to: source)
        let changed = DispatchSemaphore(value: 0)
        let watcher = PluginPreviewPackageWatcher(directory: package) { changed.signal() }
        try watcher.start()
        try Data("two".utf8).write(to: source, options: .atomic)
        precondition(changed.wait(timeout: .now() + 5) == .success, "atomic save not detected")
        watcher.stop()
        Thread.sleep(forTimeInterval: 0.4)
        while changed.wait(timeout: .now()) == .success {}
        try Data("three".utf8).write(to: source, options: .atomic)
        precondition(changed.wait(timeout: .now() + 0.8) == .timedOut, "watcher not stopped")
        print("整包监听与停止测试通过")
    }
}
