import XCTest
import AppKit
@testable import Switchly

/// 监控预热只补缺失的缓存：已有缓存截图的窗口不再预热。
final class WindowMonitorIdleTests: XCTestCase {
    @MainActor
    func testProductQueryDoesNotResolveUnrelatedOverlayTwins() throws {
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let url = try XCTUnwrap(finder.bundleURL)
        let monitor = ProductScopedMonitor(settingsService: IdleMonitorSettings(), thumbnailService: RecordingThumbnails(cachedIDs: []))
        monitor.fixtures = [
            WindowInfo(id: 801, ownerPID: finder.processIdentifier, ownerName: "Finder", windowTitle: "Target",
                       bounds: CGRect(x: 0, y: 0, width: 200, height: 200), isOnCurrentSpace: true, windowNumber: 801),
            WindowInfo(id: 802, ownerPID: -42, ownerName: "Other", windowTitle: "Other",
                       bounds: CGRect(x: 0, y: 0, width: 200, height: 200), isOnCurrentSpace: true, windowNumber: 802),
        ]
        XCTAssertEqual(monitor.windows(ownedBy: url).map(\.id), [801])
        XCTAssertEqual(monitor.resolvedIDs, [801], "其他产品不能进入本次同步 AX 去重路径")
        XCTAssertEqual(monitor.screenReads, 1)
    }

    @MainActor
    func testOverlayTwinCacheMissReturnsBeforeAXProvider() async throws {
        let providerStarted = expectation(description: "AX provider starts")
        let refreshed = expectation(description: "filtered cache publishes refresh")
        let releaseProvider = DispatchSemaphore(value: 0)
        let calls = LockedQueryProbe()
        let pid = try finderPID()
        let windows = [
            overlayWindow(id: 811, ownerPID: pid),
            overlayWindow(id: 812, ownerPID: pid),
        ]
        let monitor = OverlayFixtureMonitor(
            fixtures: windows,
            provider: { _, _ in
                calls.recordCall()
                providerStarted.fulfill()
                releaseProvider.wait()
                return [windows[0].id]
            }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: monitor, queue: nil
        ) { _ in refreshed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let startedAt = Date()
        let immediate = monitor.removeOverlayTwins(from: windows)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(immediate.map(\.id), windows.map(\.id))
        XCTAssertLessThan(elapsed, 0.2, "cache miss 不能同步等待 AX")
        await fulfillment(of: [providerStarted], timeout: 1)
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls.wasCalledOnMainThread)
        releaseProvider.signal()
        await fulfillment(of: [refreshed], timeout: 1)
    }

    @MainActor
    func testRepeatedOverlayTwinMissesUseOneInFlightQuery() async throws {
        let providerStarted = expectation(description: "AX provider starts")
        let refreshed = expectation(description: "filtered cache publishes refresh")
        let releaseProvider = DispatchSemaphore(value: 0)
        let calls = LockedQueryProbe()
        let pid = try finderPID()
        let windows = [
            overlayWindow(id: 821, ownerPID: pid),
            overlayWindow(id: 822, ownerPID: pid),
        ]
        let monitor = OverlayFixtureMonitor(
            fixtures: windows,
            provider: { _, _ in
                calls.recordCall()
                providerStarted.fulfill()
                releaseProvider.wait()
                return [windows[0].id]
            }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: monitor, queue: nil
        ) { _ in refreshed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        for _ in 0..<12 {
            XCTAssertEqual(monitor.removeOverlayTwins(from: windows).map(\.id), windows.map(\.id))
        }
        await fulfillment(of: [providerStarted], timeout: 1)
        XCTAssertEqual(calls.count, 1, "相同 cache miss 只能有一个在途查询")

        releaseProvider.signal()
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(monitor.removeOverlayTwins(from: windows).map(\.id), [windows[0].id])
    }

    @MainActor
    func testLateOverlayTwinSignatureIsRejected() async throws {
        let providerStarted = expectation(description: "AX provider starts")
        let unexpectedRefresh = expectation(description: "late signature must not refresh")
        unexpectedRefresh.isInverted = true
        let releaseProvider = DispatchSemaphore(value: 0)
        let calls = LockedQueryProbe()
        let pid = try finderPID()
        let requested = [
            overlayWindow(id: 831, ownerPID: pid),
            overlayWindow(id: 832, ownerPID: pid),
        ]
        let current = [
            overlayWindow(id: 833, ownerPID: pid),
            overlayWindow(id: 834, ownerPID: pid),
        ]
        let monitor = OverlayFixtureMonitor(
            fixtures: requested,
            provider: { _, _ in
                if calls.recordCall() == 1 {
                    providerStarted.fulfill()
                    releaseProvider.wait()
                }
                return [requested[0].id]
            }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: monitor, queue: nil
        ) { _ in unexpectedRefresh.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = monitor.removeOverlayTwins(from: requested)
        await fulfillment(of: [providerStarted], timeout: 1)
        monitor.fixtures = current
        releaseProvider.signal()
        await fulfillment(of: [unexpectedRefresh], timeout: 0.25)

        XCTAssertEqual(monitor.removeOverlayTwins(from: current).map(\.id), current.map(\.id))
    }

    @MainActor
    func testLateOverlayTwinRevisionIsRejected() async throws {
        let providerStarted = expectation(description: "AX provider starts")
        let unexpectedRefresh = expectation(description: "late revision must not refresh")
        unexpectedRefresh.isInverted = true
        let releaseProvider = DispatchSemaphore(value: 0)
        let pid = try finderPID()
        let windows = [
            overlayWindow(id: 841, ownerPID: pid),
            overlayWindow(id: 842, ownerPID: pid),
        ]
        let monitor = OverlayFixtureMonitor(
            fixtures: windows,
            provider: { _, _ in
                providerStarted.fulfill()
                releaseProvider.wait()
                return [windows[0].id]
            }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: monitor, queue: nil
        ) { _ in unexpectedRefresh.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = monitor.removeOverlayTwins(from: windows)
        await fulfillment(of: [providerStarted], timeout: 1)
        monitor.stopMonitoring()
        releaseProvider.signal()
        await fulfillment(of: [unexpectedRefresh], timeout: 0.25)
    }

    @MainActor
    func testFailedOverlayTwinQueryRetainsWindowsAndDoesNotRetry() async throws {
        let unexpectedRefresh = expectation(description: "failed query must not refresh")
        unexpectedRefresh.isInverted = true
        let calls = LockedQueryProbe()
        let pid = try finderPID()
        let windows = [
            overlayWindow(id: 851, ownerPID: pid),
            overlayWindow(id: 852, ownerPID: pid),
        ]
        let monitor = OverlayFixtureMonitor(
            fixtures: windows,
            provider: { _, _ in
                calls.recordCall()
                return nil
            }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: monitor, queue: nil
        ) { _ in unexpectedRefresh.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = monitor.removeOverlayTwins(from: windows)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls.count, 1)
        for _ in 0..<10 {
            XCTAssertEqual(monitor.removeOverlayTwins(from: windows).map(\.id), windows.map(\.id))
        }
        XCTAssertEqual(calls.count, 1, "失败结果在 TTL 内不能无限重试")
        await fulfillment(of: [unexpectedRefresh], timeout: 0.2)
    }

    @MainActor
    func testOverlayTwinFilterPreservesOtherAndUnknownSpaceWindows() async throws {
        let refreshed = expectation(description: "filtered cache publishes refresh")
        let pid = try finderPID()
        let currentTwins = [
            overlayWindow(id: 861, ownerPID: pid),
            overlayWindow(id: 862, ownerPID: pid),
        ]
        let otherSpace = overlayWindow(id: 863, ownerPID: pid, isCurrentSpace: false, isOtherSpace: true)
        let unknownSpace = overlayWindow(id: 864, ownerPID: pid, isCurrentSpace: false)
        let windows = currentTwins + [otherSpace, unknownSpace]
        let monitor = OverlayFixtureMonitor(
            fixtures: windows,
            provider: { _, _ in [currentTwins[0].id] }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .windowListDidRefresh, object: monitor, queue: nil
        ) { _ in refreshed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertEqual(monitor.removeOverlayTwins(from: windows).map(\.id), windows.map(\.id))
        await fulfillment(of: [refreshed], timeout: 1)

        XCTAssertEqual(
            monitor.removeOverlayTwins(from: windows).map(\.id),
            [currentTwins[0].id, otherSpace.id, unknownSpace.id]
        )
    }

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
            forName: .windowListDidRefresh, object: monitor, queue: nil
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

    private func finderPID() throws -> pid_t {
        try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        ).processIdentifier
    }

    private func overlayWindow(
        id: CGWindowID,
        ownerPID: pid_t,
        isCurrentSpace: Bool = true,
        isOtherSpace: Bool = false
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: ownerPID,
            ownerName: "Finder",
            windowTitle: "Twin \(id)",
            bounds: CGRect(x: 100, y: 100, width: 300, height: 200),
            isOnCurrentSpace: isCurrentSpace,
            windowNumber: Int(id),
            isOnOtherSpace: isOtherSpace
        )
    }
}

private final class OverlayFixtureMonitor: WindowMonitorService {
    var fixtures: [WindowInfo]

    init(
        fixtures: [WindowInfo],
        provider: @escaping (pid_t, [WindowInfo]) -> Set<CGWindowID>?
    ) {
        self.fixtures = fixtures
        super.init(
            settingsService: IdleMonitorSettings(),
            thumbnailService: RecordingThumbnails(cachedIDs: []),
            overlayTwinAXProvider: provider,
            overlayTwinProcessIdentityProvider: { _ in "fixture-process" },
            overlayTwinClock: { Date() }
        )
    }

    override func getOnScreenWindows() -> [WindowInfo] { fixtures }
}

private final class LockedQueryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    private var recordedOnMainThread = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    var wasCalledOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedOnMainThread
    }

    @discardableResult
    func recordCall() -> Int {
        lock.lock()
        recordedCount += 1
        recordedOnMainThread = Thread.isMainThread
        let callNumber = recordedCount
        lock.unlock()
        return callNumber
    }
}

private final class ProductScopedMonitor: WindowMonitorService {
    override var isWindowDiscoveryLimited: Bool { true }
    var fixtures: [WindowInfo] = []
    var resolvedIDs: [CGWindowID] = []
    var screenReads = 0
    override func getOnScreenWindows() -> [WindowInfo] { screenReads += 1; return fixtures }
    override func removeOverlayTwins(from windows: [WindowInfo]) -> [WindowInfo] {
        resolvedIDs = windows.map(\.id)
        return windows
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
