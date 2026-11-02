import XCTest
@testable import Switchly

/// 只验证发行制品与宿主协议互操作；算法断言在插件仓库。
final class ExternalPluginIntegrationTests: XCTestCase {
    func testPreinstalledArtifactsLoadThroughPublicRuntimeWithSafeCapabilityFakes() async throws {
        let directory = try XCTUnwrap(PluginRegistry.builtinDirectory)
        let result = PluginRegistry(directory: directory, origin: .builtin).reload()
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.plugins.isEmpty, "正式集成测试必须包含固定预装制品")
        for package in result.plugins {
            let context = PluginRenderContext(bundleID: try XCTUnwrap(package.manifest.matches.first), pid: 0,
                                              appName: "Fixture", windowID: 0, titleSummary: "")
            let runtime = PluginRuntime(package: package, mediaBridge: IntegrationMediaBridge(),
                                        permissions: Set(package.manifest.permissions).subtracting([.fsRead]))
            _ = try await runtime.render(context: context).get()
            runtime.unmount()
        }
    }

    func testUserCannotShadowPreinstalledIdentity() throws {
        let directory = try XCTUnwrap(PluginRegistry.builtinDirectory)
        let original = try XCTUnwrap(PluginRegistry(directory: directory, origin: .builtin).reload().plugins.first)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original.directory, to: scratch.appendingPathComponent("copy"))
        let result = PluginRegistry(searchPaths: [.init(directory: directory, origin: .builtin),
                                                  .init(directory: scratch, origin: .user)]).reload()
        XCTAssertEqual(result.plugins.filter { $0.manifest.id == original.manifest.id }.map(\.origin), [.builtin])
        XCTAssertEqual(result.failures.count, 1)
    }
}

private final class IntegrationMediaBridge: MediaBridging, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.external.media")
    func supports(bundleID: String) -> Bool { true }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
    func artwork(bundleID: String) throws -> Data? { nil }
}
