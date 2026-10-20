//
//  ThumbnailServiceTests.swift
//  SwitchlyTests
//
//  Unit tests for the tiered, downsampling thumbnail cache.
//
//  None of these tests capture a window: they exercise the cache policy through
//  `storeEntryForTesting`, so they run with no screen-recording permission, in
//  CI, and on a headless machine. That covers the properties worth locking
//  down — the bitmap is really resampled, eviction is synchronous and per-tier,
//  tiers do not cross-serve, a recycled CGWindowID is rejected.
//
//  Note: these assert bitmap geometry (CGImage.width/height), not RSS. An
//  earlier attempt to measure the cache with resident_size proved unusable —
//  macOS compresses uniform-colour pages, so a synthetic 31.6 MB bitmap can
//  register as ~0 MB. See docs/plan/2026-09-28-preview-panel-live-switch.md.
//

import XCTest
import AppKit
@testable import Switchly

final class ThumbnailCacheTests: XCTestCase {

    /// Byte size the cache should charge for a bitmap of this pixel size:
    /// 4 bytes per pixel, the format `downsample` produces.
    private func bytes(_ w: Int, _ h: Int) -> Int { w * h * 4 }

    // MARK: - Fixtures

    private func makeWindow(
        id: CGWindowID,
        pid: pid_t = 1000,
        owner: String = "App",
        title: String = "Window"
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: pid,
            ownerName: owner,
            windowTitle: title,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: true,
            windowNumber: Int(id)
        )
    }

    /// An opaque source bitmap standing in for a captured window.
    private func makeSourceImage(width: Int, height: Int) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            fatalError("could not create fixture context")
        }
        context.setFillColor(CGColor(red: 0.20, green: 0.60, blue: 0.90, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.90, green: 0.20, blue: 0.30, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    func testMemoryPressureCanReleaseCachedImage() {
        let service = ThumbnailService()
        let window = makeWindow(id: 42)
        weak var releasedImage: NSImage?
        autoreleasepool {
            let image = service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 100, height: 100))
            releasedImage = image
            XCTAssertNotNil(service.getCachedThumbnail(for: window, tier: .grid))
        }
        service.purgeImagesForTesting()

        XCTAssertNil(releasedImage, "元数据不得强引用图片，否则 NSCache 无法响应内存压力")
        XCTAssertNil(service.getCachedThumbnail(for: window, tier: .grid))
        XCTAssertEqual(service.cacheStatistics(tier: .grid).totalCost, 0)
    }

    func testDifferentTierCannotReattributeAnOldImageToARecycledWindowID() {
        let service = ThumbnailService()
        let original = makeWindow(id: 42, pid: 100, title: "旧窗口")
        let replacement = makeWindow(id: 42, pid: 101, title: "新窗口")
        service.storeEntryForTesting(window: original, tier: .grid, pixelSize: CGSize(width: 240, height: 150))
        service.storeEntryForTesting(window: replacement, tier: .native, pixelSize: CGSize(width: 800, height: 600))

        XCTAssertNil(service.getCachedThumbnail(for: replacement, tier: .grid), "另一层级的元数据更新不能让旧图属于新窗口")
        XCTAssertNotNil(service.getCachedThumbnail(for: replacement, tier: .native))
    }

    func testPurgingFallbackImageDoesNotReleaseAnActiveCaptureClaim() {
        let service = ThumbnailService()
        let window = makeWindow(id: 42)
        XCTAssertTrue(service.claimPreheat(windowID: window.id, tier: .grid))
        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 240, height: 150))
        service.purgeImagesForTesting()
        XCTAssertNil(service.getCachedThumbnail(for: window))
        XCTAssertFalse(service.claimPreheat(windowID: window.id, tier: .grid), "缓存清理不能结束仍在进行的后台截图")
    }

    func testConcurrentPreheatClaimsOnlyScheduleOneCapture() {
        let service = ThumbnailService()
        let countLock = NSLock()
        var admitted = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if service.claimPreheat(windowID: 42, tier: .grid) {
                countLock.lock()
                admitted += 1
                countLock.unlock()
            }
        }
        XCTAssertEqual(admitted, 1, "同一窗口同一层级只能有一个捕获任务")
        XCTAssertTrue(service.claimPreheat(windowID: 42, tier: .native), "不同层级仍可独立捕获")
        XCTAssertTrue(service.claimPreheat(windowID: 43, tier: .grid), "不同窗口仍可独立捕获")
    }

    func testOversizedImageIsReleasedImmediately() {
        let service = ThumbnailService(nativeBudget: TierBudget(byteLimit: 1, countLimit: 1))
        weak var releasedImage: NSImage?
        autoreleasepool {
            releasedImage = service.storeEntryForTesting(
                window: makeWindow(id: 42), tier: .native, pixelSize: CGSize(width: 100, height: 100)
            )
        }
        XCTAssertNil(releasedImage, "超预算图片淘汰后不能重新放回 NSCache")
        XCTAssertEqual(service.cacheStatistics(tier: .native).totalCost, 0)
    }

    func testConcurrentTimeoutFailuresKeepCooldownBounded() {
        let service = ThumbnailService()
        let window = makeWindow(id: 42)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        }
        let cooldown = service.failureCooldownRemainingForTesting(window: window, tier: .grid)
        XCTAssertGreaterThan(cooldown, 590)
        XCTAssertLessThanOrEqual(cooldown, 600)
    }

    func testPreheatSkipsFreshImagesAndFailureCooldown() {
        let service = ThumbnailService()
        let window = makeWindow(id: 42)
        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 100, height: 100))
        XCTAssertFalse(service.claimPreheat(windowID: window.id, tier: .grid))
        service.markFailedForTesting(window: window, tier: .native)
        XCTAssertFalse(service.claimPreheat(windowID: window.id, tier: .native))
    }

    // MARK: - 1. Downsampling resamples the bitmap for real

    func testDownsampleReturnsExactRequestedPixelSize() {
        let source = makeSourceImage(width: 3488, height: 2000)

        for (w, h) in [(480, 300), (1200, 750), (32, 18), (1, 1)] {
            guard let out = ThumbnailService.downsample(source, width: w, height: h) else {
                XCTFail("downsample returned nil for \(w)x\(h)")
                continue
            }
            XCTAssertEqual(out.width, w, "width not honoured for \(w)x\(h)")
            XCTAssertEqual(out.height, h, "height not honoured for \(w)x\(h)")
        }
    }

    /// The regression the whole change exists for. The previous implementation
    /// declared a small logical `NSImage.size` over a native-resolution bitmap;
    /// assert the output really holds the small pixel count.
    func testDownsampleShrinksRealPixelCountNotJustLogicalSize() {
        let source = makeSourceImage(width: 3840, height: 2160)
        guard let out = ThumbnailService.downsample(source, width: 240, height: 135) else {
            return XCTFail("downsample returned nil")
        }

        let sourcePixels = source.width * source.height
        let outPixels = out.width * out.height

        XCTAssertLessThan(outPixels, sourcePixels / 100, "expected at least a 100x pixel reduction")
        XCTAssertEqual(outPixels, 240 * 135)
        XCTAssertEqual(outPixels * 4, 129_600)
    }

    func testDownsampleRejectsDegenerateSizes() {
        let source = makeSourceImage(width: 100, height: 100)
        XCTAssertNil(ThumbnailService.downsample(source, width: 0, height: 10))
        XCTAssertNil(ThumbnailService.downsample(source, width: 10, height: 0))
        XCTAssertNil(ThumbnailService.downsample(source, width: -4, height: -4))
    }

    // MARK: - 2. fittedPixelSize: aspect-preserving, never upscales

    func testFittedPixelSizePinsOneAxisAndPreservesAspect() {
        let source = CGSize(width: 3488, height: 2000)          // aspect 1.744
        let box = CGSize(width: 480, height: 300)               // aspect 1.600
        let fitted = ThumbnailService.fittedPixelSize(source: source, into: box)

        XCTAssertLessThanOrEqual(fitted.width, box.width)
        XCTAssertLessThanOrEqual(fitted.height, box.height)
        XCTAssertTrue(fitted.width == box.width || fitted.height == box.height,
                      "one axis must be pinned to the box, got \(fitted)")

        let aspectDelta = abs((fitted.width / fitted.height) - (source.width / source.height))
        XCTAssertLessThan(aspectDelta, 0.02, "aspect ratio drifted: \(fitted)")
    }

    func testFittedPixelSizeNeverUpscales() {
        let source = CGSize(width: 300, height: 200)
        let fitted = ThumbnailService.fittedPixelSize(source: source, into: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(fitted, source, "a window smaller than the target must stay at native size")
    }

    func testFittedPixelSizeHandlesDegenerateInput() {
        let box = CGSize(width: 480, height: 300)
        XCTAssertEqual(ThumbnailService.fittedPixelSize(source: .zero, into: box), .zero)
        XCTAssertEqual(
            ThumbnailService.fittedPixelSize(source: CGSize(width: 100, height: 50), into: .zero),
            CGSize(width: 100, height: 50)
        )
    }

    // MARK: - 3. Eviction is synchronous, not advisory

    /// Byte budget. A 1000x1000 entry costs 4,000,000 bytes; with a 4 MB budget
    /// exactly one entry can survive.
    func testEvictionKeepsTotalCostUnderByteBudget() {
        let service = ThumbnailService(
            gridBudget: TierBudget(byteLimit: 4 * 1024 * 1024, countLimit: 1000)
        )
        let size = CGSize(width: 1000, height: 1000)

        for index in 0..<10 {
            service.storeEntryForTesting(
                window: makeWindow(id: CGWindowID(index)),
                tier: .grid,
                pixelSize: size
            )
        }

        let stats = service.cacheStatistics(tier: .grid)
        XCTAssertLessThanOrEqual(stats.totalCost, stats.byteLimit, "byte budget exceeded")
        XCTAssertEqual(stats.entries, 1, "10 x 4 MB into a 4 MB budget must leave exactly 1")
        XCTAssertEqual(stats.totalCost, 4_000_000, "cost must track the surviving entry exactly")
    }

    /// Entry-count budget, reachable only with tiny entries — this is the
    /// `countLimit` half of `evictIfNeededLocked`, which the byte test above
    /// never touches.
    func testEvictionKeepsEntryCountUnderLimit() {
        let service = ThumbnailService(
            gridBudget: TierBudget(byteLimit: 64 * 1024 * 1024, countLimit: 5)
        )
        let size = CGSize(width: 4, height: 4)

        for index in 0..<50 {
            service.storeEntryForTesting(
                window: makeWindow(id: CGWindowID(index)),
                tier: .grid,
                pixelSize: size
            )
        }

        let stats = service.cacheStatistics(tier: .grid)
        XCTAssertEqual(stats.entries, 5, "countLimit=5 must bound the entry count")
        XCTAssertEqual(stats.totalCost, 5 * bytes(4, 4))
    }

    /// Eviction must drop the *oldest* entry, otherwise an auto-refreshing
    /// window would evict the very thumbnail the user is looking at.
    func testEvictionDropsOldestEntryFirst() {
        let service = ThumbnailService(
            gridBudget: TierBudget(byteLimit: 64 * 1024 * 1024, countLimit: 2)
        )
        let size = CGSize(width: 4, height: 4)

        for id: CGWindowID in [10, 20, 30] {
            service.storeEntryForTesting(window: makeWindow(id: id), tier: .grid, pixelSize: size)
        }

        XCTAssertNil(
            service.getCachedThumbnail(for: makeWindow(id: 10), tier: .grid),
            "window 10 is the oldest and should have been evicted"
        )
        XCTAssertNotNil(service.getCachedThumbnail(for: makeWindow(id: 20), tier: .grid))
        XCTAssertNotNil(service.getCachedThumbnail(for: makeWindow(id: 30), tier: .grid))
    }

    /// Re-storing the same key must not double-count its cost, and must refresh
    /// its position in the eviction order.
    func testRestoringSameKeyDoesNotDoubleCountCost() {
        let service = ThumbnailService()
        let window = makeWindow(id: 1)
        let size = CGSize(width: 100, height: 100)

        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: size)
        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: size)
        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: size)

        let stats = service.cacheStatistics(tier: .grid)
        XCTAssertEqual(stats.entries, 1)
        XCTAssertEqual(stats.totalCost, bytes(100, 100))
    }

    /// An entry whose own cost exceeds its tier budget must be dropped rather
    /// than loop forever trying to evict past the last element.
    func testEntryLargerThanItsOwnTierBudgetIsDropped() {
        let service = ThumbnailService(
            nativeBudget: TierBudget(byteLimit: 1, countLimit: 1)
        )
        service.storeEntryForTesting(
            window: makeWindow(id: 1),
            tier: .native,
            pixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(service.cacheStatistics(tier: .native).entries, 0)
    }

    // MARK: - 4. Tier isolation (the point of route 2)

    func testTiersDoNotCrossServe() {
        let service = ThumbnailService()
        let window = makeWindow(id: 42)

        service.storeEntryForTesting(
            window: window,
            tier: .grid,
            pixelSize: CGSize(width: 400, height: 250)
        )

        XCTAssertNotNil(service.getCachedThumbnail(for: window, tier: .grid))
        XCTAssertNil(
            service.getCachedThumbnail(for: window, tier: .native),
            "a grid thumbnail must never satisfy the replica's native tier"
        )
        XCTAssertEqual(service.entryCountForTesting(tier: .grid), 1)
        XCTAssertEqual(service.entryCountForTesting(tier: .native), 0)
    }

    /// The native tier is what the replica is for: a grid and a native entry for
    /// the same window must coexist at their own resolutions.
    func testSameWindowCoexistsAcrossTiersAtIndependentResolutions() {
        let service = ThumbnailService()
        let window = makeWindow(id: 7)

        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 400, height: 250))
        service.storeEntryForTesting(window: window, tier: .native, pixelSize: CGSize(width: 1920, height: 1080))

        XCTAssertEqual(service.storedPixelSize(for: window, tier: .grid), CGSize(width: 400, height: 250))
        XCTAssertEqual(service.storedPixelSize(for: window, tier: .native), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(service.entryCountForTesting(tier: .grid), 1)
        XCTAssertEqual(service.entryCountForTesting(tier: .native), 1)
        XCTAssertEqual(service.cacheStatistics(tier: .grid).totalCost, bytes(400, 250))
        XCTAssertEqual(service.cacheStatistics(tier: .native).totalCost, bytes(1920, 1080))
    }

    /// Regression test for the bug that motivated per-tier budgets.
    ///
    /// A native bitmap for a display-filling window at 1920x1080 pt/2x is 31.6 MB,
    /// while the grid budget is 64 MB. Under one shared pool, capturing it evicts
    /// ~83 grid thumbnails — i.e. opening the enlarged preview throws away half
    /// the grid cache. The grid must be untouched.
    ///
    /// The grid is deliberately filled to saturation first: with only a handful
    /// of grid entries the shared pool would still fit inside 64 MB and the bug
    /// would not reproduce.
    func testNativeCaptureDoesNotEvictGridEntries() {
        let service = ThumbnailService()
        let gridSize = CGSize(width: 400, height: 250)

        for index in 0..<200 {
            service.storeEntryForTesting(
                window: makeWindow(id: CGWindowID(index)),
                tier: .grid,
                pixelSize: gridSize
            )
        }

        let before = service.cacheStatistics(tier: .grid)
        XCTAssertLessThanOrEqual(before.totalCost, before.byteLimit, "grid should be saturated, not over")
        XCTAssertGreaterThan(before.entries, 150, "grid should be saturated by 200 stores")

        // The replica asks for one window at its own size: 1920x1080 pt at 2x.
        service.storeEntryForTesting(
            window: makeWindow(id: 999),
            tier: .native,
            pixelSize: CGSize(width: 3840, height: 2160)
        )

        let after = service.cacheStatistics(tier: .grid)
        XCTAssertEqual(after.entries, before.entries, "a native capture must not evict grid thumbnails")
        XCTAssertEqual(after.totalCost, before.totalCost)
        XCTAssertEqual(service.cacheStatistics(tier: .native).entries, 1)
        XCTAssertEqual(service.cacheStatistics(tier: .native).totalCost, bytes(3840, 2160))
    }

    /// The native tier is a single slot: browsing ten windows must leave one
    /// bitmap resident, not ten.
    func testNativeTierKeepsOnlyOneSlot() {
        let service = ThumbnailService()
        let size = CGSize(width: 1920, height: 1080)

        for index in 0..<10 {
            service.storeEntryForTesting(
                window: makeWindow(id: CGWindowID(index)),
                tier: .native,
                pixelSize: size
            )
        }

        let stats = service.cacheStatistics(tier: .native)
        XCTAssertEqual(stats.entries, 1)
        XCTAssertEqual(stats.totalCost, bytes(1920, 1080))
        // The most recent selection is the one that survives.
        XCTAssertNotNil(service.getCachedThumbnail(for: makeWindow(id: 9), tier: .native))
        XCTAssertNil(service.getCachedThumbnail(for: makeWindow(id: 0), tier: .native))
    }

    /// Overflowing one tier must not disturb another tier's contents.
    func testEvictionIsScopedToTheOverflowingTier() {
        let service = ThumbnailService(
            gridBudget: TierBudget(byteLimit: 64 * 1024 * 1024, countLimit: 2),
            nativeBudget: TierBudget(byteLimit: 128 * 1024 * 1024, countLimit: 2)
        )

        service.storeEntryForTesting(window: makeWindow(id: 1), tier: .native, pixelSize: CGSize(width: 100, height: 100))
        service.storeEntryForTesting(window: makeWindow(id: 2), tier: .native, pixelSize: CGSize(width: 100, height: 100))

        // Overfill only the grid.
        for index in 10..<20 {
            service.storeEntryForTesting(
                window: makeWindow(id: CGWindowID(index)),
                tier: .grid,
                pixelSize: CGSize(width: 4, height: 4)
            )
        }

        XCTAssertEqual(service.cacheStatistics(tier: .grid).entries, 2)
        XCTAssertEqual(service.cacheStatistics(tier: .native).entries, 2, "native entries must survive a grid overflow")
        XCTAssertNotNil(service.getCachedThumbnail(for: makeWindow(id: 1), tier: .native))
    }

    func testStoredPixelSizeIsNilForUnknownKey() {
        let service = ThumbnailService()
        XCTAssertNil(service.storedPixelSize(for: makeWindow(id: 555), tier: .native))
    }

    // MARK: - 4b. Failure cooldown (what stops the endless spinner)

    /// Views ask this before showing a loading spinner, so a window that cannot
    /// be captured right now (Lark/Feishu returns a blank CoreGraphics image)
    /// reports failure instead of loading forever. It is per (window, tier): a
    /// failed grid capture must not suppress the replica's native capture of the
    /// same window.
    func testFailedRecentlyIsScopedToTheFailingKey() {
        let service = ThumbnailService()
        let window = makeWindow(id: 321)

        XCTAssertFalse(service.failedRecently(for: window, tier: .grid), "nothing has failed yet")

        service.markFailedForTesting(window: window, tier: .grid)

        XCTAssertTrue(service.failedRecently(for: window, tier: .grid))
        XCTAssertFalse(service.failedRecently(for: window, tier: .native), "tiers are independent")
        XCTAssertFalse(service.failedRecently(for: makeWindow(id: 322), tier: .grid), "windows are independent")
    }

    /// A successful capture clears the cooldown for that key, so a window that
    /// recovers (its backing store finally renders) goes back to being captured
    /// normally instead of waiting out the timer.
    func testSuccessfulStoreClearsTheFailureCooldown() {
        let service = ThumbnailService()
        let window = makeWindow(id: 323)

        service.markFailedForTesting(window: window, tier: .grid)
        XCTAssertTrue(service.failedRecently(for: window, tier: .grid))

        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 10, height: 10))
        XCTAssertFalse(service.failedRecently(for: window, tier: .grid))
    }

    // MARK: - 4c. Timeout circuit breaker

    /// Every timed-out CG capture leaks the global-queue thread it was
    /// dispatched to (the call cannot be cancelled), so consecutive timeouts
    /// must escalate the cooldown instead of retrying at the tick cadence
    /// forever: 8 s → 16 s → 32 s … capped at 600 s.
    func testConsecutiveTimeoutsEscalateTheFailureCooldown() {
        let service = ThumbnailService()
        let window = makeWindow(id: 700)

        service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        let first = service.failureCooldownRemainingForTesting(window: window, tier: .grid)
        XCTAssertGreaterThan(first, 7, "first timeout is roughly the base cooldown")
        XCTAssertLessThanOrEqual(first, 9)

        service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        let second = service.failureCooldownRemainingForTesting(window: window, tier: .grid)
        XCTAssertGreaterThan(second, 15, "second timeout doubles the cooldown")
        XCTAssertLessThanOrEqual(second, 17)

        for _ in 0..<10 {
            service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        }
        let capped = service.failureCooldownRemainingForTesting(window: window, tier: .grid)
        XCTAssertLessThanOrEqual(capped, 600, "the escalating cooldown is capped")
        XCTAssertGreaterThan(capped, 500)
    }

    /// Plain failures (nil image, blank capture) keep the flat cooldown —
    /// they cost nothing but a round trip, so there is nothing to escalate
    /// against.
    func testPlainFailuresKeepTheFlatCooldown() {
        let service = ThumbnailService()
        let window = makeWindow(id: 701)

        for _ in 0..<4 {
            service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureFailed)
        }
        let remaining = service.failureCooldownRemainingForTesting(window: window, tier: .grid)
        XCTAssertGreaterThan(remaining, 7)
        XCTAssertLessThanOrEqual(remaining, 9)
    }

    /// A successful capture resets the strike count, so a window that recovers
    /// after one timeout is back to the base cooldown on its next failure.
    func testSuccessfulStoreResetsTimeoutStrikes() {
        let service = ThumbnailService()
        let window = makeWindow(id: 702)

        service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        XCTAssertGreaterThan(
            service.failureCooldownRemainingForTesting(window: window, tier: .grid), 15
        )

        service.storeEntryForTesting(window: window, tier: .grid, pixelSize: CGSize(width: 4, height: 4))
        service.markFailedForTesting(window: window, tier: .grid, error: ThumbnailError.captureTimedOut)
        let reset = service.failureCooldownRemainingForTesting(window: window, tier: .grid)
        XCTAssertLessThanOrEqual(reset, 9, "success must reset the strike counter")
    }

    // MARK: - 4d. Owner-scoped refresh interest

    /// Refresh interest is merged across every registered surface: the preview
    /// panel and the dock preview panel used to overwrite each other's
    /// whole-tier set every second while both were visible, so whichever
    /// published last was the only one whose windows auto-refreshed.
    func testRefreshInterestIsMergedAcrossOwners() {
        let service = ThumbnailService()
        let panelA = NSObject()
        let panelB = NSObject()

        service.setRefreshInterest([1, 2], owner: panelA, tier: .grid)
        service.setRefreshInterest([3], owner: panelB, tier: .grid)

        XCTAssertEqual(service.refreshInterestForTesting(tier: .grid), [1, 2, 3], "interest must be the union of all owners")
    }

    /// One panel going away clears only its own registration; the other
    /// panel's windows keep auto-refreshing.
    func testClearingOneOwnerKeepsTheOthersInterest() {
        let service = ThumbnailService()
        let panelA = NSObject()
        let panelB = NSObject()

        service.setRefreshInterest([1, 2], owner: panelA, tier: .grid)
        service.setRefreshInterest([3], owner: panelB, tier: .grid)
        service.clearRefreshInterest(owner: panelA)

        XCTAssertEqual(service.refreshInterestForTesting(tier: .grid), [3])

        // An empty publish removes just that owner's registration too.
        service.setRefreshInterest([], owner: panelB, tier: .grid)
        XCTAssertEqual(service.refreshInterestForTesting(tier: .grid), [])
    }

    /// The replica tier is independent of the grid tier's registrations.
    func testInterestTiersStaySeparate() {
        let service = ThumbnailService()
        let panel = NSObject()

        service.setRefreshInterest([1], owner: panel, tier: .grid)
        service.setRefreshInterest([2], owner: panel, tier: .native)

        XCTAssertEqual(service.refreshInterestForTesting(tier: .grid), [1])
        XCTAssertEqual(service.refreshInterestForTesting(tier: .native), [2])

        service.clearRefreshInterest(owner: panel)
        XCTAssertEqual(service.refreshInterestForTesting(tier: .grid), [])
        XCTAssertEqual(service.refreshInterestForTesting(tier: .native), [])
    }

    // MARK: - 5. Stale / recycled window IDs

    /// macOS recycles CGWindowIDs. A recycled ID with a different owner must
    /// never be served the previous window's pixels.
    func testRecycledWindowIDWithNewOwnerIsRejected() {
        let service = ThumbnailService()
        let original = makeWindow(id: 99, pid: 500, owner: "Safari", title: "Original")
        service.storeEntryForTesting(window: original, tier: .grid, pixelSize: CGSize(width: 100, height: 100))
        XCTAssertNotNil(service.getCachedThumbnail(for: original, tier: .grid))

        let recycled = makeWindow(id: 99, pid: 501, owner: "Finder", title: "Original")
        XCTAssertNil(
            service.getCachedThumbnail(for: recycled, tier: .grid),
            "same window ID, different owner PID must not hit"
        )
    }

    func testSameWindowIDWithDifferentTitleIsRejected() {
        let service = ThumbnailService()
        let before = makeWindow(id: 5, pid: 500, title: "Untitled")
        service.storeEntryForTesting(window: before, tier: .grid, pixelSize: CGSize(width: 100, height: 100))

        let after = makeWindow(id: 5, pid: 500, title: "saved-document.txt")
        XCTAssertNil(
            service.getCachedThumbnail(for: after, tier: .grid),
            "same window ID, different title must not hit"
        )
    }

    // MARK: - 6. Cache key semantics

    func testCacheKeyEqualityAndHashing() {
        let base = ThumbnailCacheKey(77, .grid)

        XCTAssertEqual(base, ThumbnailCacheKey(77, .grid))
        XCTAssertEqual(base.hash, ThumbnailCacheKey(77, .grid).hash)
        XCTAssertNotEqual(base, ThumbnailCacheKey(77, .native))
        XCTAssertNotEqual(base, ThumbnailCacheKey(78, .grid))

        var set = Set<ThumbnailCacheKey>()
        set.insert(base)
        set.insert(ThumbnailCacheKey(77, .grid))
        set.insert(ThumbnailCacheKey(77, .native))
        set.insert(ThumbnailCacheKey(78, .grid))
        XCTAssertEqual(set.count, 3, "one duplicate should have collapsed")
    }

    // MARK: - 7. Tier enum contract

    func testTierEnumIsStable() {
        XCTAssertEqual(ThumbnailTier.allCases.count, 2)
        XCTAssertEqual(Set(ThumbnailTier.allCases), [.grid, .native])
        // String raw values are persisted in notification userInfo; renaming
        // one silently would break the view side's lookups.
        XCTAssertEqual(ThumbnailTier.grid.rawValue, "grid")
        XCTAssertEqual(ThumbnailTier.native.rawValue, "native")
    }

    func testPixelDimensionsScalePointsToPixels() {
        XCTAssertEqual(ThumbnailSize.small.dimensions, CGSize(width: 160, height: 100))
        XCTAssertEqual(ThumbnailSize.small.pixelDimensions(scale: 2), CGSize(width: 320, height: 200))
        XCTAssertEqual(ThumbnailSize.large.pixelDimensions(scale: 2), CGSize(width: 480, height: 300))
        XCTAssertEqual(ThumbnailSize.large.pixelDimensions(scale: 1), CGSize(width: 240, height: 150))
        // Degenerate scale must not collapse the thumbnail to zero pixels.
        XCTAssertEqual(ThumbnailSize.large.pixelDimensions(scale: 0), CGSize(width: 240, height: 150))
        XCTAssertEqual(ThumbnailSize.large.pixelDimensions(scale: -2), CGSize(width: 240, height: 150))
    }

    // MARK: - 8. Budget policy matches the documented numbers

    func testTierBudgetsMatchTheDocumentedPolicy() {
        XCTAssertEqual(TierBudget.grid.byteLimit, 64 * 1024 * 1024)
        XCTAssertEqual(TierBudget.grid.countLimit, 200)
        XCTAssertEqual(TierBudget.native.countLimit, 1)

        // The native slot must never self-evict on a display that exists today:
        // the largest is a 6K Pro Display XDR at 2x, 6016x3384x4 = 81.4 MB —
        // which is also the tier's pixel cap.
        XCTAssertGreaterThan(TierBudget.native.byteLimit, bytes(6016, 3384))

        // The grid budget must comfortably hold a busy workspace of tiles.
        XCTAssertGreaterThan(TierBudget.grid.byteLimit / bytes(400, 250), 150)

        // Envelope worst case — an upper bound, not typical usage. Recorded so a
        // future change that inflates it has to do so deliberately.
        let worstCase = TierBudget.grid.byteLimit + TierBudget.native.byteLimit
        XCTAssertEqual(worstCase, 192 * 1024 * 1024)
    }
}
