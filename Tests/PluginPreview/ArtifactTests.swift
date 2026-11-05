import AppKit
import Foundation

@main
struct ArtifactTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-artifacts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"id":"com.example.plugin","name":{"en":"Example"},"version":"1","apiVersion":1,"matches":["com.example.app"],"permissions":[],"entry":"main.js"}"#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        try Data("one".utf8).write(to: package.appendingPathComponent("main.js"))
        let first = try PluginPreviewPackageHasher.sha256(packageURL: package)
        let repeated = try PluginPreviewPackageHasher.sha256(packageURL: package)
        precondition(first == repeated)
        try Data("two".utf8).write(to: package.appendingPathComponent("main.js"))
        let changed = try PluginPreviewPackageHasher.sha256(packageURL: package)
        precondition(first != changed)
        let snapshot = root.appendingPathComponent("snapshot")
        let snapshotHash = try PluginPreviewPackageHasher.snapshot(packageURL: package, destination: snapshot)
        precondition(snapshotHash == changed)
        do { _ = try PluginPreviewPackageHasher.snapshot(packageURL: package, destination: snapshot); fatalError("overwrote snapshot") }
        catch PluginPreviewArtifactError.invalidPackage {}
        precondition(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("main.js").path))
        let link = package.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try PluginPreviewPackageHasher.sha256(packageURL: package); fatalError("accepted symlink") }
        catch PluginPreviewArtifactError.invalidPackage {}
        try FileManager.default.removeItem(at: link)

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 0, y: 0)
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = root.appendingPathComponent("capture.png")
        try png.write(to: image)
        let raw = Data(#"[{"slot":"center","node":{"type":"button","id":"go","symbol":"play","label":"Play","size":"m","enabled":false}}]"#.utf8)
        let identity = PluginPreviewArtifactIdentity(scenarioID: "s", pluginID: "com.example.plugin", pluginVersion: "1", generation: 1, packageURL: package,
                                                     scenarioSource: .derived)
        let out = root.appendingPathComponent("out")
        let report = try PluginPreviewArtifactWriter().writeSuccess(identity: identity, rawJSON: raw, screenshotURL: image, outputDirectory: out)
        precondition(report.status == .passed)
        precondition(report.scenarioSource == .derived)
        let tree = try Data(contentsOf: out.appendingPathComponent("ui-tree.json"))
        precondition(tree == raw)
        let actions = try JSONDecoder().decode(PluginPreviewArtifactActions.self, from: Data(contentsOf: out.appendingPathComponent("actions.json")))
        precondition(actions.actions.count == 1 && !actions.actions[0].enabled)
        do { _ = try PluginPreviewArtifactWriter().writeSuccess(identity: identity, rawJSON: raw, screenshotURL: image, outputDirectory: out); fatalError("overwrote output") }
        catch PluginPreviewArtifactError.outputNotEmpty {}
        let bad = root.appendingPathComponent("bad.png")
        try Data([137,80,78,71,13,10,26,10]).write(to: bad)
        do { _ = try PluginPreviewArtifactWriter().writeSuccess(identity: identity, rawJSON: raw, screenshotURL: bad, outputDirectory: root.appendingPathComponent("bad-out")); fatalError("accepted invalid PNG") }
        catch PluginPreviewArtifactError.invalidScreenshot {}

        // 无 steps 的报告不出现 steps 键；有 steps 时成功与失败报告都带 trace。
        let reportJSON = try String(contentsOf: out.appendingPathComponent("report.json"), encoding: .utf8)
        precondition(!reportJSON.contains("\"steps\""), "reports without steps keep their existing shape")
        precondition(reportJSON.contains("\"scenarioSource\" : \"derived\""))
        let traces = [PluginPreviewStepTrace(index: 0, type: "advance", source: "clock", status: "passed", detail: nil)]
        let withSteps = try PluginPreviewArtifactWriter().writeSuccess(identity: identity, rawJSON: raw, screenshotURL: image,
            outputDirectory: root.appendingPathComponent("steps-out"), steps: traces)
        precondition(withSteps.steps == traces)
        let failedOut = root.appendingPathComponent("failed-out")
        let failedTraces = [PluginPreviewStepTrace(index: 0, type: "expectText", source: "render-output", status: "failed", detail: "text-not-found")]
        let failed = try PluginPreviewArtifactWriter().writeFailure(identity: identity, status: .failed, failure: .stepFailed,
            outputDirectory: failedOut, steps: failedTraces)
        precondition(failed.status == .failed && failed.failure?.code == "step-failed" && failed.artifacts == .reportOnly)
        let decoded = try JSONDecoder().decode(PluginPreviewArtifactReport.self, from: Data(contentsOf: failedOut.appendingPathComponent("report.json")))
        precondition(decoded.steps == failedTraces)
        print("产物、哈希与 PNG 测试通过")
    }
}
