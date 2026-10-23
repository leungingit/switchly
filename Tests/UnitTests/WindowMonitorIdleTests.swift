import XCTest
import AppKit
@testable import Switchly

/// 监控预热只补缺失的缓存：已有缓存截图的窗口不再预热。
final class WindowMonitorIdleTests: XCTestCase {
    @MainActor
    func testOnlyWindowsWithoutCachedThumbnailsArePreheated() {
        let cached = Self.window(id: 1)
        let missing = Self.window(id: 2)
        let thumbnails = RecordingThumbnails(cachedIDs: [cached.id])
        let monitor = FixedWindowsMonitor(windows: [cached, missing], thumbnails: thumbnails)

        monitor.processWindowChanges(reason: "timer")

        XCTAssertEqual(thumbnails.preheated.flatMap { $0 }, [missing.id])
    }

    @MainActor
    func testFullyCachedWindowsNeverTriggerPreheat() {
        let windows = [Self.window(id: 1), Self.window(id: 2)]
        let thumbnails = RecordingThumbnails(cachedIDs: Set(windows.map(\.id)))
        let monitor = FixedWindowsMonitor(windows: windows, thumbnails: thumbnails)

        for _ in 0..<50 { monitor.processWindowChanges(reason: "timer") }
        monitor.processWindowChanges(reason: "activated:test")

        XCTAssertTrue(thumbnails.preheated.isEmpty, "全部已有缓存时不应再预热截图")
    }

    @MainActor
    func testPreheatBatchIsCappedPerTick() {
        let windows = (1...20).map { Self.window(id: CGWindowID($0)) }
        let thumbnails = RecordingThumbnails(cachedIDs: [])
        let monitor = FixedWindowsMonitor(windows: windows, thumbnails: thumbnails)

        monitor.processWindowChanges(reason: "timer")

        XCTAssertEqual(thumbnails.preheated.first?.count, 8)
    }

    @MainActor
    func testMonitorStillNotifiesVisibleConsumers() {
        let monitor = FixedWindowsMonitor(windows: [], thumbnails: RecordingThumbnails(cachedIDs: []))
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        monitor.processWindowChanges(reason: "timer")

        XCTAssertEqual(notifications, 1)
    }

    private static func window(id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id, ownerPID: 1, ownerName: "Test", windowTitle: "W\(id)",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isOnCurrentSpace: true, windowNumber: Int(id)
        )
    }
}

private final class FixedWindowsMonitor: WindowMonitorService {
    let windows: [WindowInfo]

    init(windows: [WindowInfo], thumbnails: ThumbnailServiceProtocol) {
        self.windows = windows
        super.init(settingsService: IdleMonitorSettings(), thumbnailService: thumbnails)
    }

    override func getOnScreenWindows() -> [WindowInfo] { windows }
}

private final class RecordingThumbnails: ThumbnailServiceProtocol {
    let cachedIDs: Set<CGWindowID>
    var preheated: [[CGWindowID]] = []

    init(cachedIDs: Set<CGWindowID>) { self.cachedIDs = cachedIDs }

    func captureThumbnail(for window: WindowInfo, size: CGSize, tier: ThumbnailTier) async throws -> NSImage { NSImage() }
    func getCachedThumbnail(for window: WindowInfo, tier: ThumbnailTier) -> NSImage? {
        cachedIDs.contains(window.id) ? NSImage() : nil
    }
    func preheatThumbnails(for windows: [WindowInfo], size: CGSize, tier: ThumbnailTier, reason: String) {}
    func preheatUncachedThumbnails(for windows: [WindowInfo], size: CGSize, reason: String) {
        preheated.append(windows.map(\.id))
    }
    func setRefreshInterest(_ windowIDs: Set<CGWindowID>, owner: AnyObject, tier: ThumbnailTier) {}
    func clearRefreshInterest(owner: AnyObject) {}
    func startAutoRefresh() {}
    func stopAutoRefresh() {}
}

private final class IdleMonitorSettings: SettingsServiceProtocol {
    func loadSettings() -> AppSettings { AppSettings.default }
    func saveSettings(_ settings: AppSettings) throws {}
    func observeChanges(_ handler: @escaping (AppSettings) -> Void) {}
}
