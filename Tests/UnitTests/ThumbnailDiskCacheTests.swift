import AppKit
import XCTest
@testable import Switchly

final class ThumbnailDiskCacheTests: XCTestCase {
    private var root: URL!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Switchly-thumbnail-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func window(id: CGWindowID = 42, title: String = "测试窗口", pid: pid_t = 100) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, ownerName: "测试应用", windowTitle: title,
                   bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                   isOnCurrentSpace: true, windowNumber: Int(id))
    }

    private func cache(now: Date? = nil, limit: Int = ThumbnailDiskCache.byteLimit,
                       boot: String = "boot-a", launch: Date? = nil) -> ThumbnailDiskCache {
        let current = now ?? date
        let launchDate = launch ?? date.addingTimeInterval(-1000)
        return ThumbnailDiskCache(directory: root.appendingPathComponent("cache"), byteLimit: limit, now: { current }) {
            ThumbnailDiskIdentity(bootSession: boot, bundlePath: "/Applications/Test.app",
                processID: $0.ownerPID, processLaunchDate: launchDate, windowID: $0.id, title: $0.windowTitle)
        }
    }

    private func thumbnail(at: Date? = nil, width: Int = 240, height: Int = 150) -> PersistedThumbnail {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return PersistedThumbnail(image: NSImage(cgImage: context.makeImage()!, size: CGSize(width: width / 2, height: height / 2)),
                                  capturedAt: at ?? date, pixelSize: CGSize(width: width, height: height))
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "thumbnail" }
    }

    func testNewCacheInstanceRestoresImageAndOriginalTimestamp() async throws {
        let first = cache()
        let original = thumbnail(at: date.addingTimeInterval(-600))
        first.save(original, for: window())
        let saved = await first.load(for: window())
        XCTAssertNotNil(saved)
        let second = cache()
        let restored = await second.load(for: window())
        let result = try XCTUnwrap(restored)
        XCTAssertEqual(result.capturedAt, original.capturedAt)
        XCTAssertEqual(result.pixelSize, original.pixelSize)
        XCTAssertEqual(result.image.size, original.image.size)
        XCTAssertEqual(try files().count, 1)
    }

    func testExitFlushWaitsForAlreadyQueuedWrites() throws {
        let disk = cache()
        disk.save(thumbnail(), for: window())
        disk.flush(timeout: 2)
        XCTAssertEqual(try files().count, 1)
    }

    func testExpiredImagesAreNotRestoredAndAreDeleted() async throws {
        let first = cache()
        first.save(thumbnail(), for: window())
        _ = await first.load(for: window())
        let expired = cache(now: date.addingTimeInterval(ThumbnailDiskCache.retention))
        let result = await expired.load(for: window())
        XCTAssertNil(result)
        XCTAssertTrue(try files().isEmpty)
    }

    func testReadingDoesNotExtendRetention() async throws {
        let first = cache()
        first.save(thumbnail(), for: window())
        _ = await first.load(for: window())
        let later = cache(now: date.addingTimeInterval(ThumbnailDiskCache.retention - 1))
        let old = await later.load(for: window())
        XCTAssertEqual(old?.capturedAt, date)
        let expired = cache(now: date.addingTimeInterval(ThumbnailDiskCache.retention + 1))
        let result = await expired.load(for: window())
        XCTAssertNil(result)
    }

    func testChangedProcessBootWindowOrTitleCannotReuseImage() async {
        let first = cache()
        first.save(thumbnail(), for: window())
        _ = await first.load(for: window())
        let restarted = cache(launch: date.addingTimeInterval(-500))
        let afterRestart = await restarted.load(for: window())
        let rebooted = cache(boot: "boot-b")
        let afterReboot = await rebooted.load(for: window())
        let changedPID = await first.load(for: window(pid: 101))
        let changedID = await first.load(for: window(id: 43))
        let changedTitle = await first.load(for: window(title: "另一窗口"))
        XCTAssertNil(afterRestart)
        XCTAssertNil(afterReboot)
        XCTAssertNil(changedPID)
        XCTAssertNil(changedID)
        XCTAssertNil(changedTitle)
    }

    func testBudgetEvictsOldestFile() async throws {
        let first = cache()
        first.save(thumbnail(at: date.addingTimeInterval(-100)), for: window(id: 1))
        _ = await first.load(for: window(id: 1))
        let file = try XCTUnwrap(try files().first)
        let size = try XCTUnwrap(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let bounded = cache(limit: size + 100)
        bounded.save(thumbnail(), for: window(id: 2))
        let new = await bounded.load(for: window(id: 2))
        let old = await bounded.load(for: window(id: 1))
        XCTAssertNotNil(new)
        XCTAssertNil(old)
        let total = try files().reduce(0) { sum, url in
            sum + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, size + 100)
    }

    func testOversizedFileIsNeverStored() async throws {
        let bounded = cache(limit: 1)
        bounded.save(thumbnail(), for: window())
        let result = await bounded.load(for: window())
        XCTAssertNil(result)
        XCTAssertTrue(try files().isEmpty)
    }

    func testCorruptFileIsRemovedWithoutFailingCapture() async throws {
        let disk = cache()
        disk.save(thumbnail(), for: window())
        _ = await disk.load(for: window())
        let file = try XCTUnwrap(try files().first)
        try Data("损坏的缓存".utf8).write(to: file)
        let result = await disk.load(for: window())
        XCTAssertNil(result)
        XCTAssertTrue(try files().isEmpty)
    }

    func testOlderWriteCannotOverwriteNewerCapture() async {
        let disk = cache()
        disk.save(thumbnail(), for: window())
        disk.save(thumbnail(at: date.addingTimeInterval(-100)), for: window())
        let result = await disk.load(for: window())
        XCTAssertEqual(result?.capturedAt, date)
    }

    func testCacheUsesPrivatePermissionsAndHasNoPlaintextTitle() async throws {
        let disk = cache()
        disk.save(thumbnail(), for: window())
        _ = await disk.load(for: window())
        let file = try XCTUnwrap(try files().first)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertFalse(file.lastPathComponent.contains(window().windowTitle))
        let record = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertNil(record["title"])
        XCTAssertNil(record["bundlePath"])
    }

    func testDiskImageIsLimitedToSmallThumbnailResolution() async throws {
        let disk = cache()
        disk.save(thumbnail(width: 2400, height: 1500), for: window())
        let result = await disk.load(for: window())
        let restored = try XCTUnwrap(result)
        XCTAssertEqual(restored.pixelSize, CGSize(width: 1200, height: 750))
    }

    func testUnresolvableIdentityDoesNotReadOrWriteImages() async {
        let disk = ThumbnailDiskCache(directory: root.appendingPathComponent("cache"), identity: { _ in nil })
        disk.save(thumbnail(), for: window())
        let result = await disk.load(for: window())
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    func testProductionIdentityIsStableForCurrentProcess() throws {
        let fixture = window(pid: ProcessInfo.processInfo.processIdentifier)
        let first = try XCTUnwrap(ThumbnailDiskIdentity.resolve(fixture))
        XCTAssertEqual(first.key, ThumbnailDiskIdentity.resolve(fixture)?.key)
    }
}

private final class FixtureThumbnailDiskCache: ThumbnailDiskCaching {
    private let queue = DispatchQueue(label: "com.switchly.tests.thumbnailDisk")
    private let thumbnail: PersistedThumbnail?
    private var loadCount = 0
    private var saveCount = 0
    private var pending: CheckedContinuation<PersistedThumbnail?, Never>?
    var waitForRelease = false
    var onLoad: (() -> Void)?

    init(_ thumbnail: PersistedThumbnail?) { self.thumbnail = thumbnail }
    var loads: Int { queue.sync { loadCount } }
    var saves: Int { queue.sync { saveCount } }

    func load(for window: WindowInfo) async -> PersistedThumbnail? {
        await withCheckedContinuation { continuation in
            let suspended = queue.sync {
                loadCount += 1
                if waitForRelease { pending = continuation }
                return waitForRelease
            }
            onLoad?()
            if !suspended { continuation.resume(returning: thumbnail) }
        }
    }

    func save(_ thumbnail: PersistedThumbnail, for window: WindowInfo) {
        queue.sync { saveCount += 1 }
    }

    func release() {
        let continuation = queue.sync {
            let result = pending
            pending = nil
            return result
        }
        continuation?.resume(returning: thumbnail)
    }
}

@MainActor
final class ThumbnailRestoreTests: XCTestCase {
    private var window: WindowInfo {
        WindowInfo(id: 42, ownerPID: 100, ownerName: "测试应用", windowTitle: "测试窗口",
                   bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                   isOnCurrentSpace: true, windowNumber: 42)
    }

    private func saved(at: Date = Date().addingTimeInterval(-120)) -> PersistedThumbnail {
        PersistedThumbnail(image: NSImage(size: CGSize(width: 120, height: 75)), capturedAt: at,
                           pixelSize: CGSize(width: 240, height: 150))
    }

    func testDiskFallbackIsReturnedDuringCaptureFailureCooldown() async throws {
        let original = saved()
        let disk = FixtureThumbnailDiskCache(original)
        let service = ThumbnailService(diskCache: disk, screenCaptureAccess: { true })
        service.markFailedForTesting(window: window, tier: .grid)

        let image = try await service.captureThumbnail(for: window, size: CGSize(width: 120, height: 75))
        XCTAssertTrue(image === original.image)
        XCTAssertTrue(service.failedRecently(for: window, tier: .grid), "恢复图片不能清除截图失败退避")
        XCTAssertEqual(disk.loads, 1)
        XCTAssertEqual(disk.saves, 0, "恢复旧图不得重写文件并延长有效期")
    }

    func testDiskFallbackDoesNotWaitForAnInFlightCapture() async {
        let original = saved()
        let service = ThumbnailService(diskCache: FixtureThumbnailDiskCache(original), screenCaptureAccess: { true })
        XCTAssertTrue(service.claimPreheat(windowID: window.id, tier: .grid))
        let delivered = expectation(description: "旧图无需等待截图完成")
        let task = Task {
            let image = try? await service.captureThumbnail(for: window, size: CGSize(width: 120, height: 75))
            XCTAssertTrue(image === original.image)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2)
        task.cancel()
    }

    func testRestoredImageKeepsItsOriginalFreshness() async {
        let service = ThumbnailService(diskCache: FixtureThumbnailDiskCache(saved()), screenCaptureAccess: { true })
        let image = await service.restoreCachedThumbnail(for: window)
        XCTAssertNotNil(image)
        XCTAssertTrue(service.claimPreheat(windowID: window.id, tier: .grid), "旧图仍需后台刷新，恢复不能视为刚截图")
    }

    func testExpiredDiskFallbackIsRejected() async {
        let expired = saved(at: Date().addingTimeInterval(-ThumbnailDiskCache.retention - 1))
        let service = ThumbnailService(diskCache: FixtureThumbnailDiskCache(expired), screenCaptureAccess: { true })
        let image = await service.restoreCachedThumbnail(for: window)
        XCTAssertNil(image)
        XCTAssertNil(service.getCachedThumbnail(for: window))
    }

    func testPermissionDeniedDoesNotReadDiskImages() async {
        let disk = FixtureThumbnailDiskCache(saved())
        let service = ThumbnailService(diskCache: disk, screenCaptureAccess: { false })
        let image = await service.restoreCachedThumbnail(for: window)
        XCTAssertNil(image)
        XCTAssertEqual(disk.loads, 0)
    }

    func testNativeCaptureDoesNotReadOrWriteDiskCache() async {
        let disk = FixtureThumbnailDiskCache(saved())
        let service = ThumbnailService(diskCache: disk, screenCaptureAccess: { false })
        _ = service.storeEntryForTesting(window: window, tier: .native, pixelSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(disk.saves, 0)
        service.purgeImagesForTesting()
        do {
            _ = try await service.captureThumbnail(for: window, size: CGSize(width: 400, height: 300), tier: .native)
            XCTFail("无录屏权限时不应截图")
        } catch {}
        XCTAssertEqual(disk.loads, 0)
        XCTAssertEqual(disk.saves, 0)
    }

    func testSuccessfulGridCaptureIsSaved() {
        let disk = FixtureThumbnailDiskCache(nil)
        let service = ThumbnailService(diskCache: disk)
        _ = service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 240, height: 150))
        XCTAssertEqual(disk.saves, 1)
    }

    func testFailedBackgroundRefreshPreservesOldImage() async {
        let service = ThumbnailService(screenCaptureAccess: { false })
        let original = service.storeEntryForTesting(window: window, tier: .grid,
            pixelSize: CGSize(width: 240, height: 150), capturedAt: Date().addingTimeInterval(-120))
        let failed = expectation(description: "后台刷新失败")
        let observer = NotificationCenter.default.addObserver(forName: .thumbnailDidUpdate, object: nil, queue: .main) { note in
            if note.object as? CGWindowID == 42, note.userInfo?["failed"] as? Bool == true { failed.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let immediate = try? await service.captureThumbnail(for: window, size: CGSize(width: 120, height: 75))
        XCTAssertTrue(immediate === original)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(service.getCachedThumbnail(for: window) === original)
    }

    func testLateDiskReadCannotOverwriteFreshMemoryImage() async {
        let disk = FixtureThumbnailDiskCache(saved())
        disk.waitForRelease = true
        let reading = expectation(description: "读盘已开始")
        disk.onLoad = { reading.fulfill() }
        let service = ThumbnailService(diskCache: disk, screenCaptureAccess: { true })
        let task = Task {
            let image = await service.restoreCachedThumbnail(for: window)
            return image === service.getCachedThumbnail(for: window)
        }
        await fulfillment(of: [reading], timeout: 2)
        let fresh = service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 240, height: 150))
        disk.release()
        let matchesLatest = await task.value
        XCTAssertTrue(matchesLatest)
        XCTAssertTrue(service.getCachedThumbnail(for: window) === fresh)
        XCTAssertEqual(disk.saves, 1)
    }

    func testCancelledRestoreDoesNotPublishAnImage() async {
        let disk = FixtureThumbnailDiskCache(saved())
        disk.waitForRelease = true
        let reading = expectation(description: "读盘已开始")
        disk.onLoad = { reading.fulfill() }
        let service = ThumbnailService(diskCache: disk, screenCaptureAccess: { true })
        let task = Task {
            let image = await service.restoreCachedThumbnail(for: window)
            return image == nil
        }
        await fulfillment(of: [reading], timeout: 2)
        task.cancel()
        disk.release()
        let wasDiscarded = await task.value
        XCTAssertTrue(wasDiscarded)
        XCTAssertNil(service.getCachedThumbnail(for: window))
    }
}
