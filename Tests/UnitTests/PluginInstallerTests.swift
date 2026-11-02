import XCTest
@testable import Switchly

final class PluginInstallerTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    private func fixture(name: String = "source", version: String = "1.0.0") throws -> URL {
        let directory = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"id":"com.example.fixture","name":{"en":"Fixture"},"version":"\(version)","apiVersion":1,
         "matches":["com.example.target"],"permissions":[],"entry":"main.js"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("globalThis.__switchlyPlugin={render:()=>[]};".utf8).write(to: directory.appendingPathComponent("main.js"))
        return directory
    }

    func testInstallUpdateAndUninstallKeepUnrelatedPackages() throws {
        let destination = temporary.appendingPathComponent("installed")
        let installer = PluginInstaller(destination: destination, builtinIDs: { [] })
        let first = try fixture()
        XCTAssertEqual(try installer.install(directory: first).version, "1.0.0")
        let updated = try fixture(name: "update", version: "1.1.0")
        XCTAssertEqual(try installer.install(directory: updated).version, "1.1.0")
        let snapshot = PluginRegistry(directory: destination).reload()
        XCTAssertEqual(snapshot.plugins.map { $0.manifest.version }, ["1.1.0"])
        XCTAssertTrue(snapshot.failures.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".install-") })
        try installer.uninstall(id: "com.example.fixture")
        XCTAssertTrue(PluginRegistry(directory: destination).reload().plugins.isEmpty)
    }

    func testInvalidUpdatePreservesInstalledVersion() throws {
        let destination = temporary.appendingPathComponent("installed")
        let installer = PluginInstaller(destination: destination, builtinIDs: { [] })
        _ = try installer.install(directory: fixture())
        let bad = try fixture(name: "invalid", version: "2.0.0")
        try FileManager.default.removeItem(at: bad.appendingPathComponent("main.js"))
        XCTAssertThrowsError(try installer.install(directory: bad))
        XCTAssertEqual(PluginRegistry(directory: destination).reload().plugins.first?.manifest.version, "1.0.0")
    }

    func testBuiltinConflictAndSymlinkAreRejected() throws {
        let source = try fixture()
        let installer = PluginInstaller(destination: temporary.appendingPathComponent("installed"), builtinIDs: { ["com.example.fixture"] })
        XCTAssertThrowsError(try installer.install(directory: source))
        XCTAssertThrowsError(try installer.uninstall(id: "com.example.fixture"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path,
                                                  withDestinationPath: temporary.path)
        XCTAssertThrowsError(try PluginPackageValidator.load(directory: source, origin: .user))
    }

    func testDuplicateSettingsAreRejectedBeforeRuntime() throws {
        let source = try fixture()
        let url = source.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let setting: [String: Any] = ["key": "same", "title": ["en": "Same"], "default": false]
        json["settings"] = [setting, setting]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try PluginPackageValidator.load(directory: source, origin: .user))
    }
}
