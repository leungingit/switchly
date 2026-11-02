import XCTest
@testable import Switchly

final class PluginStorageTests: XCTestCase {
    func testStoragePersistsAndIsolatesPlugins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PluginStorage(pluginID: "com.example.a", directory: root)
        let other = PluginStorage(pluginID: "com.example.b", directory: root)
        try first.set("state", value: ["round": 3])
        XCTAssertNil(try other.get("state"))
        let reopened = PluginStorage(pluginID: "com.example.a", directory: root)
        XCTAssertEqual((try reopened.get("state") as? [String: Int])?["round"], 3)
        try reopened.remove("state")
        XCTAssertNil(try first.get("state"))
        try first.set("value", value: true)
        try first.clear()
        XCTAssertNil(try first.get("value"))
    }

    func testQuotaRejectsWriteWithoutLosingPreviousValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStorage(pluginID: "com.example.a", directory: root)
        try store.set("value", value: "old")
        XCTAssertThrowsError(try store.set("value", value: String(repeating: "x", count: PluginStorage.maxValueBytes)))
        XCTAssertEqual(try store.get("value") as? String, "old")
        XCTAssertThrowsError(try store.set("", value: "invalid"))
    }
}
