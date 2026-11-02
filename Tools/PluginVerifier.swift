import Foundation

/// 与 App 共享 Runtime/解码器的独立进程；只连接假系统能力，不读用户授权目录。
@main
struct PluginVerifier {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("用法：switchly-plugin-verify <插件目录>\n", stderr)
            exit(2)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let package = try PluginPackageValidator.load(directory: URL(fileURLWithPath: CommandLine.arguments[1]), origin: .user)
            let media = VerificationMedia()
            let runtime = PluginRuntime(package: package, timeout: 1, mediaBridge: media,
                permissions: Set(package.manifest.permissions).subtracting([.fsRead]), libraryBridge: media,
                storage: PluginStorage(pluginID: package.manifest.id, directory: scratch), reduceMotion: { true })
            let context = PluginRenderContext(bundleID: package.manifest.matches[0], pid: 0,
                                              appName: "Fixture", windowID: 0, titleSummary: "")
            let slots = try await runtime.render(context: context).get()
            runtime.unmount()
            print("真实 JSC 与宿主解码校验通过：\(package.manifest.id)，槽位数 \(slots.count)；系统能力为假实现，fs.read 未授权")
        } catch {
            fputs("宿主契约校验失败：\(error)\n", stderr)
            exit(1)
        }
    }
}

private final class VerificationMedia: MediaBridging, MusicLibraryPlaying, @unchecked Sendable {
    let queue = DispatchQueue(label: "switchly.verifier.media")
    func supports(bundleID: String) -> Bool { true }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
    func artwork(bundleID: String) throws -> Data? { nil }
    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? { nil }
    func play(persistentID: String) throws {}
    func pausePlayback() throws {}
    func currentTrack() throws -> NowPlaying? { nil }
}
