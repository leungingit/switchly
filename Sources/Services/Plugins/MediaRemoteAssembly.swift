import AppKit

/// 真实系统依赖的唯一装配入口。策略桥不负责查询进程、构造子进程或选择安装路径。
/// 正常宿主从自身资源目录装配；构造本身不启动采集，测试可显式传入候选位置。
enum MediaRemoteAssembly {
    static func makeBridge(bundle: Bundle = .main) -> CompositeMediaBridge {
        let directory = bundle.bundleURL.appendingPathComponent("Contents/Resources/MediaRemoteAdapter", isDirectory: true)
        return makeBridge(configuration: MediaRemoteLaunchConfiguration(directory: directory))
    }

    static func makeBridge(configuration: MediaRemoteLaunchConfiguration,
                           script: MusicAppleScriptBridge = MusicAppleScriptBridge()) -> CompositeMediaBridge {
        let identity: () -> MediaRemoteProcessIdentity? = {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: MediaRemoteState.bundleID).first,
                  let launchDate = app.launchDate else { return nil }
            return MediaRemoteProcessIdentity(pid: app.processIdentifier, launchDate: launchDate)
        }
        let stream = MediaRemoteStream { FoundationMediaRemoteChildProcess(configuration: configuration) }
        let session = MediaRemoteSession(stream: stream, identity: identity)
        return CompositeMediaBridge(script: script, session: session, identity: identity)
    }
}
