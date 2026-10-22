import XCTest
import AppKit
@testable import Switchly

final class WindowMonitorIdleTests: XCTestCase {
    @MainActor
    func testIdleTimerStillNotifiesVisibleConsumersWithoutEnumerating() async {
        let monitor = EnumerationTrackingMonitor(settingsService: IdleMonitorSettings())
        let updates = expectation(description: "启动和真实监控计时器均发出通知")
        updates.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: nil, queue: nil
        ) { _ in updates.fulfill() }
        defer {
            monitor.stopMonitoring()
            NotificationCenter.default.removeObserver(observer)
        }
        monitor.startMonitoring()
        await fulfillment(of: [updates], timeout: 4)
        XCTAssertEqual(monitor.enumerations, 0)
    }

    @MainActor
    func testIdleMonitorNotifiesWithoutEnumeratingOrPreheatingWindows() {
        let settings = IdleMonitorSettings()
        let monitor = EnumerationTrackingMonitor(settingsService: settings)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: nil, queue: nil
        ) { _ in
            notifications += 1
        }
        defer {
            monitor.stopMonitoring()
            NotificationCenter.default.removeObserver(observer)
        }

        monitor.startMonitoring()
        let startupNotifications = notifications
        XCTAssertGreaterThanOrEqual(startupNotifications, 1)
        // 直接驱动监控入口，避免测试宿主的共享监控同时消费全局应用通知。
        for _ in 0..<100 {
            monitor.processWindowChanges(reason: "timer")
        }
        monitor.processWindowChanges(reason: "activated:test")
        XCTAssertEqual(notifications, startupNotifications + 101)
        XCTAssertEqual(monitor.enumerations, 0, "空闲监控不能枚举并预热前台或受监控窗口")
    }
}

private final class EnumerationTrackingMonitor: WindowMonitorService {
    var enumerations = 0

    override func getOnScreenWindows() -> [WindowInfo] {
        enumerations += 1
        return []
    }
}

private final class IdleMonitorSettings: SettingsServiceProtocol {
    func loadSettings() -> AppSettings {
        var settings = AppSettings.default
        settings.monitorFrequency = .highPerformance
        return settings
    }
    func saveSettings(_ settings: AppSettings) throws {}
    func observeChanges(_ handler: @escaping (AppSettings) -> Void) {}
}
