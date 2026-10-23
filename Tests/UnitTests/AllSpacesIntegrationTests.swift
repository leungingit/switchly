import AppKit
import ApplicationServices
import XCTest
@testable import Switchly

/// 只读实机枚举验证；需先用受控应用在两个桌面各打开一个窗口。
final class AllSpacesIntegrationTests: XCTestCase {
    @MainActor
    func testFindsControlledWindowsAcrossSpaces() async throws {
        guard ProcessInfo.processInfo.environment["SWITCHLY_TEST_ALL_SPACES"] == "1" else {
            throw XCTSkip("需显式开启受控跨桌面实机验证")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("测试宿主没有辅助功能权限") }
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.switchly.spacesfixture").first)
        let service = WindowMonitorService.shared
        let deadline = Date().addingTimeInterval(15)
        var windows = service.getAllWindows()
        while service.isEnumeratingWindows && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            windows = service.getAllWindows()
        }
        XCTAssertFalse(service.isEnumeratingWindows, "枚举未在期限内完成")
        let fixtures = windows.filter { $0.ownerPID == app.processIdentifier }
        XCTAssertEqual(fixtures.count, 2, "两个受控窗口都必须被发现，不能混入辅助 surface")
        XCTAssertEqual(Set(fixtures.map(\.id)).count, 2)
        XCTAssertTrue(fixtures.contains { $0.isOnCurrentSpace })
        XCTAssertTrue(fixtures.contains { $0.isOnOtherSpace && !$0.isMinimized })
    }
}
