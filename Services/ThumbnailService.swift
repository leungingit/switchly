//
//  ThumbnailService.swift
//  Switchly
//
//  Service for generating and caching window thumbnails
//

import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

protocol ThumbnailServiceProtocol {
    func captureThumbnail(for window: WindowInfo, size: CGSize, tier: ThumbnailTier) async throws -> NSImage
    func getCachedThumbnail(for window: WindowInfo, tier: ThumbnailTier) -> NSImage?
    func preheatThumbnails(for windows: [WindowInfo], size: CGSize, tier: ThumbnailTier, reason: String)
    /// Publishes the window IDs one interested surface (panel) is showing for
    /// one tier. Registrations are owner-scoped and merged, so two visible
    /// panels never overwrite each other's interest. Pass an empty set to
    /// remove the owner's registration for that tier.
    func setRefreshInterest(_ windowIDs: Set<CGWindowID>, owner: AnyObject, tier: ThumbnailTier)
    /// Removes one owner's registrations from every tier (its panel went
    /// away) without touching other panels' registrations.
    func clearRefreshInterest(owner: AnyObject)
    func startAutoRefresh()
    func stopAutoRefresh()
}

extension ThumbnailServiceProtocol {
    // Grid-tier conveniences.
    //
    // All three preview surfaces (preview panel, dock hover, workspace bar) only
    // ever want the grid tier, and all of them pass `settings.thumbnailSize`
    // (points). Defaulting the tier here keeps those call sites — 9 lookups and
    // 3 captures — untouched now that a tier dimension exists, so adding a tier
    // cannot silently break one of the other two surfaces.

    func captureThumbnail(for window: WindowInfo, size: CGSize) async throws -> NSImage {
        try await captureThumbnail(for: window, size: size, tier: .grid)
    }

    func getCachedThumbnail(for window: WindowInfo) -> NSImage? {
        getCachedThumbnail(for: window, tier: .grid)
    }

    func preheatThumbnails(for windows: [WindowInfo], size: CGSize, reason: String) {
        preheatThumbnails(for: windows, size: size, tier: .grid, reason: reason)
    }

    func setRefreshInterest(_ windowIDs: Set<CGWindowID>, owner: AnyObject) {
        setRefreshInterest(windowIDs, owner: owner, tier: .grid)
    }
}

/// Cache key: window + tier.
///
/// `NSCache` requires an object key with correct `hash` / `isEqual`, so window
/// identity (which is size independent) can no longer be the whole key.
final class ThumbnailCacheKey: NSObject {
    let windowID: CGWindowID
    let tier: ThumbnailTier

    init(_ windowID: CGWindowID, _ tier: ThumbnailTier) {
        self.windowID = windowID
        self.tier = tier
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(windowID)
        hasher.combine(tier)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ThumbnailCacheKey else {
            return false
        }
        return other.windowID == windowID && other.tier == tier
    }

    override var description: String {
        "window=\(windowID), tier=\(tier.rawValue)"
    }
}

class ThumbnailService: ThumbnailServiceProtocol {
    /// Holds the images so the system can still purge them under memory
    /// pressure. Cost-based eviction is NOT delegated to it — see
    /// `evictIfNeededLocked`.
    private let cache = NSCache<ThumbnailCacheKey, NSImage>()
    private let lock = NSLock()
    private let diskCache: ThumbnailDiskCaching?
    private let screenCaptureAccess: () -> Bool
    private let preheatQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.switchly.thumbnailPreheat"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    /// Runs blocking capture bodies. Concurrent by design: each request has
    /// already been admitted by the preheat gate or comes from a view, and
    /// serialising them here would put the enlarged preview's first frame behind
    /// a queue of grid tiles.
    private let captureQueue = DispatchQueue(
        label: "com.switchly.thumbnailCapture",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Upper bound on capture pipelines running at once. Each pipeline parks a
    /// coordinator thread on `captureQueue` (waiting out the CG timeout) plus
    /// the thread that actually runs `CGWindowListCreateImage`, so an
    /// unbounded cold-start burst — a grid of cards whose `.task`s all fire
    /// together — can push the process toward the GCD thread ceiling. Waiters
    /// are suspended continuations, never blocked threads.
    private static let maxConcurrentCaptures = 6
    private var activeCaptureCount = 0
    private var captureAdmissionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Window identity, size independent. Keyed by window id alone so the
    /// auto-refresh tick can rebuild a `WindowInfo` for any tier.
    private var windowMeta: [CGWindowID: WindowMetadata] = [:]

    /// Per (window, tier) entries: freshness plus the resolution actually stored.
    private var entries: [ThumbnailCacheKey: ThumbnailEntry] = [:]

    /// Insertion/update order per tier, oldest first, for deterministic
    /// eviction. Reordered on write only — reads happen from view bodies and
    /// must stay O(1).
    private var evictionOrder: [ThumbnailTier: [ThumbnailCacheKey]] = [:]

    /// Book-kept byte totals, per tier. Tiers are budgeted independently — see
    /// `TierBudget`.
    private var tierCosts: [ThumbnailTier: Int] = [:]

    /// Entry counts per tier, kept incrementally so `evictIfNeededLocked` does
    /// not have to scan `entries` on every store.
    private var tierCounts: [ThumbnailTier: Int] = [:]

    private var inFlightKeys = Set<ThumbnailCacheKey>()
    /// Suspended callers waiting for the in-flight attempt of a key to finish.
    /// Waiters are continuations, never blocked threads — see `claimInFlight`.
    private var inFlightWaiters: [ThumbnailCacheKey: [CheckedContinuation<Void, Never>]] = [:]
    private var failedUntil: [ThumbnailCacheKey: Date] = [:]
    /// Consecutive capture timeouts per key. Every timed-out CG attempt leaks
    /// the global-queue thread it was dispatched to (the call cannot be
    /// cancelled once dispatched), so a window whose capture consistently
    /// hangs must stop being retried at the tick cadence: each strike doubles
    /// the failure cooldown, capped by `maxFailureCooldown`.
    private var timeoutStrikes: [ThumbnailCacheKey: Int] = [:]

    private let budgets: [ThumbnailTier: TierBudget]

    private let cacheExpiration: TimeInterval = 60.0
    private let failureCooldown: TimeInterval = 8.0
    /// Ceiling for the escalating timeout cooldown — see `timeoutStrikes`.
    private let maxFailureCooldown: TimeInterval = 600.0

    /// Interval at which the auto-refresh timer scans cached entries and
    /// re-captures windows that are not in-flight or in failure cooldown.
    private let autoRefreshInterval: TimeInterval = 8.0

    /// Last pixel size requested per tier. The auto-refresh tick reuses it so we
    /// don't need to read settings on the timer thread. One value per tier: the
    /// grid and the window replica legitimately want different resolutions.
    private var lastCaptureSize: [ThumbnailTier: CGSize] = [:]

    /// Main-RunLoop timer that triggers `runRefreshTick`. Held while at least
    /// one client has called `startAutoRefresh` and not yet `stopAutoRefresh`.
    private var refreshTimer: Timer?

    /// Reference count of active clients (panels / app). The timer is
    /// started on the 0→1 transition and stopped on the N→0 transition so we
    /// never leak a timer that no one will invalidate.
    private var autoRefreshClientCount: Int = 0

    /// Window IDs the visible panels currently display, per tier — merged
    /// across every interested surface (owner-scoped), so two visible panels
    /// never overwrite each other's interest the way a plain per-tier set
    /// did. The auto-refresh tick only re-captures these, so an idle app (no
    /// panel on screen) performs zero capture work. Panels publish while
    /// visible and clear their own registration on dismiss.
    private var refreshInterest: [ThumbnailTier: [ObjectIdentifier: Set<CGWindowID>]] = [:]

    /// Max time a single `CGWindowListCreateImage` call may block before we
    /// give up. On macOS 26 the CG path is internally proxied through
    /// `SLSWindowListCreateImageProxying` (ScreenCaptureKit), which can
    /// synchronously hang on a `semaphore_timedwait_trap` when the SCK stream
    /// resources are stuck. Without a timeout, every capture worker would
    /// block forever and the dock card would stay in "loading" indefinitely.
    private let captureTimeout: TimeInterval = 1.5

    /// Max time a single ScreenCaptureKit fallback attempt may run.
    private let sckCaptureTimeout: TimeInterval = 3.0

    static let shared = ThumbnailService(diskCache: ThumbnailDiskCache())

    /// Budgets are injectable so tests can drive eviction with a handful of
    /// entries instead of hundreds, and so a measurement that says a limit
    /// should differ changes a `TierBudget` rather than the class body.
    init(
        gridBudget: TierBudget = .grid,
        nativeBudget: TierBudget = .native,
        diskCache: ThumbnailDiskCaching? = nil,
        screenCaptureAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.diskCache = diskCache
        self.screenCaptureAccess = screenCaptureAccess
        self.budgets = [
            .grid: gridBudget,
            .native: nativeBudget
        ]
        // Backstop only. Real eviction is done by `evictIfNeededLocked`.
        cache.countLimit = 500
        let summary = ThumbnailTier.allCases
            .map { "\($0.rawValue)=\(self.budgets[$0]?.byteLimit ?? 0)B/\(self.budgets[$0]?.countLimit ?? 0)" }
            .joined(separator: ", ")
        AppLogger.debug("ThumbnailService initialized. budgets: \(summary)")
    }

    // MARK: - Capture

    func flushPersistentCache(timeout: TimeInterval) {
        diskCache?.flush(timeout: timeout)
    }

    func captureThumbnail(for window: WindowInfo, size: CGSize, tier: ThumbnailTier) async throws -> NSImage {
        if let cached = getCachedThumbnail(for: window, tier: tier) {
            if tier == .grid {
                preheatThumbnails(for: [window], size: size, tier: tier, reason: "cached-fallback")
            }
            AppLogger.verbose("Using cached thumbnail. windowID=\(window.id), tier=\(tier.rawValue)")
            return cached
        }

        // 磁盘恢复不等待正在进行的截图：冷启动时先交付旧图，再由预热刷新。
        if tier == .grid, let restored = await restoreCachedThumbnail(for: window) {
            preheatThumbnails(for: [window], size: size, tier: tier, reason: "disk-restore")
            return restored
        }
        try Task.checkCancellation()

        // A window that just failed stays failed until the cooldown expires:
        // re-hammering the window server on every card rebuild only queues
        // work behind the same failure. The auto-refresh tick retries once
        // the cooldown lifts. (Views gate on this too; the service is the
        // backstop for surfaces that do not.)
        if failedRecently(for: window, tier: tier) {
            throw ThumbnailError.captureFailed
        }

        let scale = Self.displayScale
        let pixelSize = Self.pixelSize(forPoints: size, scale: scale, tier: tier)
        recordCaptureSize(pixelSize, tier: tier)
        recordWindowMeta(window)

        AppLogger.debug("Capturing thumbnail. windowID=\(window.id), tier=\(tier.rawValue), pixelSize=\(pixelSize)")
        let key = ThumbnailCacheKey(window.id, tier)

        // On-demand captures coordinate with the preheat path through the
        // same in-flight set, so a card's `.task` and a background preheat
        // never run two full capture pipelines for the same (window, tier)
        // — which, at native tier, means two window-sized bitmaps at once.
        while !claimInFlight(key) {
            await waitUntilCaptureFinishes(key)
            if let cached = getCachedThumbnail(for: window, tier: tier) {
                AppLogger.verbose("Using thumbnail captured by a concurrent attempt. windowID=\(window.id), tier=\(tier.rawValue)")
                return cached
            }
            if failedRecently(for: window, tier: tier) {
                throw ThumbnailError.captureFailed
            }
        }

        do {
            let captured = try await attemptCapture(window: window, pixelSize: pixelSize, scale: scale)
            store(captured.image, key: key, window: window, pixelSize: captured.pixelSize)
            markFinished(key)
            return captured.image
        } catch {
            markFailed(key, error: error)
            markFinished(key)
            throw error
        }
    }

    /// One full capture attempt: the CoreGraphics path with short retries, then
    /// the ScreenCaptureKit fallback.
    ///
    /// Both the on-demand and the background path go through here on purpose.
    /// The preheat path used to call the CoreGraphics capture directly, so it
    /// had no ScreenCaptureKit fallback: a window whose CG capture comes back
    /// blank (Electron apps such as Lark/Feishu do this) could be preheated
    /// forever and never succeed, even though the very same window captures fine
    /// through the on-demand path. The enlarged preview reads preheated entries,
    /// so it spun forever on exactly those windows.
    private func attemptCapture(window: WindowInfo, pixelSize: CGSize, scale: CGFloat) async throws -> CapturedThumbnail {
        // Screen-recording permission is a process-wide state: when it is not
        // granted, neither the CG retries nor the SCK fallback can succeed,
        // and burning three attempts plus a shareable-content round-trip on
        // every capture only queues work behind the same denial.
        guard screenCaptureAccess() else {
            throw ThumbnailError.screenCapturePermissionDenied
        }

        await waitForCaptureSlot()
        do {
            let captured = try await performCaptureAttempts(window: window, pixelSize: pixelSize, scale: scale)
            releaseCaptureSlot()
            return captured
        } catch {
            releaseCaptureSlot()
            throw error
        }
    }

    /// The capture body proper: the CoreGraphics path with short retries, then
    /// the ScreenCaptureKit fallback.
    ///
    /// Both the on-demand and the background path go through here on purpose.
    /// The preheat path used to call the CoreGraphics capture directly, so it
    /// had no ScreenCaptureKit fallback: a window whose CG capture comes back
    /// blank (Electron apps such as Lark/Feishu do this) could be preheated
    /// forever and never succeed, even though the very same window captures fine
    /// through the on-demand path. The enlarged preview reads preheated entries,
    /// so it spun forever on exactly those windows.
    private func performCaptureAttempts(window: WindowInfo, pixelSize: CGSize, scale: CGFloat) async throws -> CapturedThumbnail {
        // Some apps (especially Electron apps) return a blank/white backing
        // store right after a window appears or is switched to. Retry with
        // short delays so the real content is captured on the first attempt.
        let retryDelays: [UInt64] = [0, 150_000_000, 350_000_000]
        var lastError: Error = ThumbnailError.captureFailed

        for delay in retryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                return try await performOffThread { [weak self] in
                    guard let self else {
                        throw ThumbnailError.captureFailed
                    }
                    return try self.captureWindowThumbnail(window, pixelSize: pixelSize, scale: scale)
                }
            } catch {
                lastError = error
            }
        }

        // The CG path returns blank for some windows (remote-desktop sessions
        // such as NoMachine, GPU/OpenGL-composited content, Electron windows).
        // Fall back to ScreenCaptureKit, which can capture content the CG API
        // cannot.
        if let captured = await captureWithScreenCaptureKit(window: window, pixelSize: pixelSize, scale: scale) {
            return captured
        }

        throw lastError
    }

    /// Runs a blocking capture body off the cooperative pool and awaits it.
    ///
    /// Deliberately not `preheatQueue`: preheat operations park while this
    /// work runs, so waiting on the same queue would let both of its threads
    /// wait for work only they could run.
    private func performOffThread(
        _ body: @escaping () throws -> CapturedThumbnail
    ) async throws -> CapturedThumbnail {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous bridge for the preheat queue, which is an `OperationQueue`.
    /// Parks its caller (a queue thread, never the main actor) while the shared
    /// attempt pipeline runs.
    private func awaitAttempt(window: WindowInfo, pixelSize: CGSize, scale: CGFloat, tier: ThumbnailTier) throws -> CapturedThumbnail {
        let box = CaptureBox()
        let done = DispatchSemaphore(value: 0)
        Task { [weak self] in
            guard let self else {
                done.signal()
                return
            }
            do {
                if tier == .grid { _ = await self.restoreCachedThumbnail(for: window) }
                box.result = .success(try await self.attemptCapture(window: window, pixelSize: pixelSize, scale: scale))
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.result.get()
    }

    private final class CaptureBox {
        var result: Result<CapturedThumbnail, Error> = .failure(ThumbnailError.captureFailed)
    }

    // MARK: - Cache reads

    func getCachedThumbnail(for window: WindowInfo, tier: ThumbnailTier) -> NSImage? {
        let key = ThumbnailCacheKey(window.id, tier)

        lock.lock()
        let entry = entries[key]
        let cached = cache.object(forKey: key)
        if cached == nil, entry != nil {
            // The system purged the image from NSCache behind our back; drop the
            // accounting entry so the byte budget stays honest.
            removeEntryLocked(key)
        }
        lock.unlock()

        let expiration = tier == .grid ? ThumbnailDiskCache.retention : cacheExpiration
        guard let entry = entry,
              let cached = cached,
              // The cache is keyed by CG window ID, which macOS recycles.
              // Verify the cached image still belongs to this exact window
              // (same owner and title) so a recycled ID can never show
              // another window's preview.
              entry.ownerPID == window.ownerPID,
              entry.title == window.windowTitle,
              Date().timeIntervalSince(entry.timestamp) >= 0,
              Date().timeIntervalSince(entry.timestamp) < expiration else {
            return nil
        }
        AppLogger.verbose("Thumbnail cache hit. windowID=\(window.id), tier=\(tier.rawValue)")
        return cached
    }

    /// 只恢复小图，保留原始截图时间；恢复和失败重试不能延长 24 小时有效期。
    func restoreCachedThumbnail(for window: WindowInfo) async -> NSImage? {
        if let cached = getCachedThumbnail(for: window, tier: .grid) { return cached }
        guard screenCaptureAccess(), let diskCache,
              let saved = await diskCache.load(for: window), !Task.isCancelled,
              screenCaptureAccess(), saved.capturedAt <= Date(),
              Date().timeIntervalSince(saved.capturedAt) < ThumbnailDiskCache.retention else { return nil }
        store(saved.image, key: ThumbnailCacheKey(window.id, .grid), window: window,
              pixelSize: saved.pixelSize, animated: false, capturedAt: saved.capturedAt, persist: false)
        return getCachedThumbnail(for: window, tier: .grid)
    }

    /// Resolution actually stored for a key, if any. Lets a caller detect that
    /// the entry was captured for a different size (e.g. the user changed
    /// `thumbnailSize`, or the preview panel was resized).
    func storedPixelSize(for window: WindowInfo, tier: ThumbnailTier) -> CGSize? {
        lock.lock()
        let entry = entries[ThumbnailCacheKey(window.id, tier)]
        lock.unlock()
        return entry?.pixelSize
    }

    // MARK: - Preheat

    func preheatThumbnails(for windows: [WindowInfo], size: CGSize, tier: ThumbnailTier, reason: String) {
        let scale = Self.displayScale
        let pixelSize = Self.pixelSize(forPoints: size, scale: scale, tier: tier)
        recordCaptureSize(pixelSize, tier: tier)

        let candidates = windows.filter { claimPreheat(windowID: $0.id, tier: tier) }
        guard !candidates.isEmpty else {
            return
        }

        AppLogger.info("Preheating thumbnails. reason=\(reason), tier=\(tier.rawValue), count=\(candidates.count)")
        for window in candidates {
            let key = ThumbnailCacheKey(window.id, tier)
            preheatQueue.addOperation { [weak self] in
                self?.captureAndCache(
                    window: window,
                    key: key,
                    pixelSize: pixelSize,
                    scale: scale,
                    reason: reason
                )
            }
        }
    }

    // MARK: - Refresh interest

    /// Publishes the window IDs one visible surface is showing for one tier;
    /// an empty set removes that owner's registration. The merged union of all
    /// owners is what the auto-refresh tick sees, so a panel can never clear
    /// another panel's interest again (the old whole-tier replacement let the
    /// preview panel and the dock preview panel overwrite each other every
    /// second while both were visible). Called on the main thread.
    func setRefreshInterest(_ windowIDs: Set<CGWindowID>, owner: AnyObject, tier: ThumbnailTier) {
        let ownerKey = ObjectIdentifier(owner)
        lock.lock()
        let previous = interestedWindowIDsLocked(tier: tier)
        if windowIDs.isEmpty {
            refreshInterest[tier]?.removeValue(forKey: ownerKey)
        } else {
            refreshInterest[tier, default: [:]][ownerKey] = windowIDs
        }
        let current = interestedWindowIDsLocked(tier: tier)
        lock.unlock()

        // Only real changes are logged. Every panel republishes its interest on
        // each window-list refresh (about once a second) for up to three tiers,
        // which filled the rotating log with identical "count=0" lines.
        guard current != previous else {
            return
        }
        AppLogger.debug("Refresh interest updated. tier=\(tier.rawValue), count=\(current.count)")
    }

    /// Removes one owner's registrations from every tier — its panel went
    /// away — without touching what other panels still show.
    func clearRefreshInterest(owner: AnyObject) {
        let ownerKey = ObjectIdentifier(owner)
        lock.lock()
        for tier in ThumbnailTier.allCases {
            refreshInterest[tier]?.removeValue(forKey: ownerKey)
        }
        lock.unlock()
    }

    /// Merged window IDs every interested surface is showing for one tier.
    /// Caller must hold `lock`.
    private func interestedWindowIDsLocked(tier: ThumbnailTier) -> Set<CGWindowID> {
        var merged: Set<CGWindowID> = []
        if let owners = refreshInterest[tier] {
            for set in owners.values {
                merged.formUnion(set)
            }
        }
        return merged
    }

    // MARK: - Auto refresh

    /// Starts (or extends the lifetime of) the background auto-refresh timer.
    /// Idempotent: multiple calls only keep the timer alive until the matching
    /// number of `stopAutoRefresh` calls have been made. Intended to be called
    /// once at app launch and once when any preview panel becomes visible.
    func startAutoRefresh() {
        lock.lock()
        autoRefreshClientCount += 1
        let shouldStart = refreshTimer == nil
        lock.unlock()

        guard shouldStart else {
            AppLogger.debug("Auto-refresh timer already running. clientCount=\(autoRefreshClientCount)")
            return
        }

        // Built unscheduled and registered exactly once, in the common
        // run-loop mode so it keeps firing during UI interaction:
        // `Timer.scheduledTimer` would already have registered it in the
        // default mode, making the `add` below a redundant second
        // registration of the same timer.
        let timer = Timer(
            timeInterval: autoRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.runRefreshTick()
        }
        RunLoop.main.add(timer, forMode: .common)

        lock.lock()
        refreshTimer = timer
        let count = autoRefreshClientCount
        lock.unlock()

        AppLogger.info("Started auto-refresh timer. interval=\(autoRefreshInterval)s, clientCount=\(count)")
    }

    /// Stops the auto-refresh timer once the last client has opted out.
    /// Idempotent and safe to call when not started.
    func stopAutoRefresh() {
        lock.lock()
        autoRefreshClientCount = max(0, autoRefreshClientCount - 1)
        let shouldStop = autoRefreshClientCount == 0
        let timer = shouldStop ? refreshTimer : nil
        if shouldStop {
            refreshTimer = nil
        }
        let count = autoRefreshClientCount
        lock.unlock()

        guard let timer else {
            AppLogger.debug("Auto-refresh stop ignored. clientCount=\(count)")
            return
        }

        timer.invalidate()
        AppLogger.info("Stopped auto-refresh timer. clientCount=\(count)")
    }

    /// One tick of the auto-refresh timer: for every tier a visible panel is
    /// showing, re-capture the interested windows that are not in-flight or in
    /// failure cooldown. Reuses `claimPreheat` so the gating logic stays
    /// identical to the event-driven preheat path; failures keep the existing
    /// cached image (we only `markFailed`, never evict), so the user always sees
    /// the last good frame rather than a loading spinner.
    private func runRefreshTick() {
        // `displayScale` reads NSScreen; this tick runs on the main thread
        // (main-RunLoop timer), and the value is captured before any capture
        // work goes off-main — see `makeThumbnail`.
        let scale = Self.displayScale
        lock.lock()
        let interest: [ThumbnailTier: Set<CGWindowID>] = refreshInterest.mapValues { owners in
            owners.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) }
        }
        let sizes = lastCaptureSize
        lock.unlock()

        var refreshed = 0
        for tier in ThumbnailTier.allCases {
            // Nothing of this tier on screen: do no work at all. This is the
            // idle path — Switchly sits in the menu bar with no panel open and
            // must not re-capture (and re-animate) anything.
            guard let interested = interest[tier], !interested.isEmpty,
                  let pixelSize = sizes[tier], pixelSize.width > 1, pixelSize.height > 1 else {
                continue
            }

            for windowID in interested {
                guard let window = windowInfo(forRefresh: windowID) else {
                    continue
                }
                guard claimPreheat(windowID: windowID, tier: tier) else {
                    continue
                }
                let key = ThumbnailCacheKey(windowID, tier)
                preheatQueue.addOperation { [weak self] in
                    self?.captureAndCache(
                        window: window,
                        key: key,
                        pixelSize: pixelSize,
                        scale: scale,
                        reason: "auto-refresh"
                    )
                }
                refreshed += 1
            }
        }

        if refreshed > 0 {
            AppLogger.verbose("Auto-refresh tick scheduled captures. count=\(refreshed)")
        }
    }

    /// Reconstructs a minimal `WindowInfo` for an auto-refresh capture. The
    /// capture path only needs identity + bounds + on-current-space; the
    /// metadata we keep in memory is enough to satisfy that without re-querying
    /// the window server.
    private func windowInfo(forRefresh windowID: CGWindowID) -> WindowInfo? {
        lock.lock()
        let meta = windowMeta[windowID]
        lock.unlock()
        guard let meta else {
            return nil
        }

        return WindowInfo(
            id: windowID,
            ownerPID: meta.ownerPID,
            ownerName: meta.ownerName,
            windowTitle: meta.title,
            bounds: meta.bounds,
            isOnCurrentSpace: meta.isOnCurrentSpace,
            windowNumber: Int(windowID)
        )
    }

    // MARK: - Entry bookkeeping

    /// Stores a captured thumbnail and notifies the UI.
    ///
    /// - Parameter animated: whether the receiving card may crossfade into
    ///   the new image. Background refreshes (auto-refresh tick) pass
    ///   `false`: the user did not ask for that frame, so it must not
    ///   animate under their cursor every few seconds. First loads (a card's
    ///   own capture task) pass `true` and keep the fade.
    private func store(
        _ image: NSImage,
        key: ThumbnailCacheKey,
        window: WindowInfo,
        pixelSize: CGSize,
        animated: Bool = true,
        capturedAt: Date = Date(),
        persist: Bool = true
    ) {
        // Byte cost of the bitmap backing this image. 4 bytes per pixel is the
        // format `downsample` produces (BGRA, alpha channel skipped).
        let cost = Int(pixelSize.width * pixelSize.height) * 4

        lock.lock()
        // 截图可能在读盘期间完成，较旧磁盘图不能覆盖新的内存图。
        if !persist, let existing = entries[key], existing.timestamp >= capturedAt,
           cache.object(forKey: key) != nil,
           existing.ownerPID == window.ownerPID,
           existing.title == window.windowTitle {
            lock.unlock()
            return
        }
        windowMeta[window.id] = WindowMetadata(
            ownerPID: window.ownerPID,
            ownerName: window.ownerName,
            title: window.windowTitle,
            bounds: window.bounds,
            isOnCurrentSpace: window.isOnCurrentSpace,
            recordedAt: Date()
        )
        if let existing = entries[key] {
            tierCosts[key.tier, default: 0] -= existing.cost
        } else {
            tierCounts[key.tier, default: 0] += 1
        }
        evictionOrder[key.tier]?.removeAll { $0 == key }
        entries[key] = ThumbnailEntry(ownerPID: window.ownerPID, title: window.windowTitle,
                                      cost: cost, pixelSize: pixelSize, timestamp: capturedAt)
        evictionOrder[key.tier, default: []].append(key)
        tierCosts[key.tier, default: 0] += cost
        if persist {
            failedUntil.removeValue(forKey: key)
            timeoutStrikes.removeValue(forKey: key)
        }
        cache.setObject(image, forKey: key)
        evictIfNeededLocked(tier: key.tier)
        let liveCost = tierCosts[key.tier] ?? 0
        let liveCount = tierCounts[key.tier] ?? 0
        lock.unlock()

        if persist, key.tier == .grid {
            diskCache?.save(PersistedThumbnail(image: image, capturedAt: capturedAt, pixelSize: pixelSize), for: window)
        }
        notifyThumbnailDidUpdate(windowID: window.id, tier: key.tier, animated: animated, failed: false)
        AppLogger.verbose("Cached thumbnail. \(key.description), pixelSize=\(pixelSize), tierCost=\(liveCost), tierEntries=\(liveCount)")
    }

    /// Announces a finished capture attempt for one (window, tier) pair.
    ///
    /// Delivered on the main thread so SwiftUI state updates don't come from a
    /// background queue (previously produced runtime warnings and could delay
    /// thumbnail card refresh).
    private func notifyThumbnailDidUpdate(
        windowID: CGWindowID,
        tier: ThumbnailTier,
        animated: Bool,
        failed: Bool
    ) {
        var userInfo: [String: Any] = ["animated": animated, "tier": tier.rawValue]
        if failed {
            userInfo["failed"] = true
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .thumbnailDidUpdate,
                object: windowID,
                userInfo: userInfo
            )
        }
    }

    /// Drops the oldest entries of one tier until that tier fits both its byte
    /// budget and its entry-count budget. Synchronous by design — a `NSCache`'s
    /// own limits are advisory (see `TierBudget`), so this is what actually
    /// bounds memory.
    ///
    /// Eviction is per tier, never global: a single full-screen bitmap is
    /// 31.6 MB on a 1920x1080 display at 2x (77.7 MB on a 6K display), so
    /// charging it against the grid's budget would throw away every cached
    /// thumbnail the moment the preview switched to full screen.
    private func evictIfNeededLocked(tier: ThumbnailTier) {
        guard let budget = budgets[tier] else {
            return
        }
        while (tierCosts[tier] ?? 0) > budget.byteLimit || (tierCounts[tier] ?? 0) > budget.countLimit,
              let oldest = evictionOrder[tier]?.first {
            evictionOrder[tier]?.removeFirst()
            removeEntryLocked(oldest)
        }
    }

    /// Removes one entry from both the accounting tables and `NSCache`.
    /// Caller must hold `lock`.
    private func removeEntryLocked(_ key: ThumbnailCacheKey) {
        if let removed = entries.removeValue(forKey: key) {
            tierCosts[key.tier, default: 0] -= removed.cost
            tierCounts[key.tier, default: 0] -= 1
        }
        evictionOrder[key.tier]?.removeAll { $0 == key }
        cache.removeObject(forKey: key)
    }

    /// Current accounting snapshot for one tier. Used by tests and diagnostics.
    func cacheStatistics(tier: ThumbnailTier) -> (entries: Int, totalCost: Int, byteLimit: Int, countLimit: Int) {
        lock.lock()
        let snapshot = (
            entries: tierCounts[tier] ?? 0,
            totalCost: tierCosts[tier] ?? 0,
            byteLimit: budgets[tier]?.byteLimit ?? 0,
            countLimit: budgets[tier]?.countLimit ?? 0
        )
        lock.unlock()
        return snapshot
    }

    /// Test seam: inserts an entry through the real `store` path without going
    /// near the window server.
    ///
    /// Unit tests cannot capture windows (no screen-recording grant in CI, and
    /// no window at all in a headless run), but the properties worth asserting
    /// — synchronous eviction under the byte budget, per-tier key isolation,
    /// recycled-window-ID rejection — all live in `store` / `evictIfNeededLocked`
    /// / `getCachedThumbnail`. This exposes those exact code paths to tests
    /// instead of reimplementing the policy in the test file, so the test
    /// cannot pass while the production path is broken.
    ///
    /// Production never calls this; the only callers are in `Tests/`.
    @discardableResult
    func storeEntryForTesting(
        window: WindowInfo,
        tier: ThumbnailTier,
        pixelSize: CGSize,
        capturedAt: Date = Date()
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height)))
        store(
            image,
            key: ThumbnailCacheKey(window.id, tier),
            window: window,
            pixelSize: pixelSize,
            capturedAt: capturedAt
        )
        return image
    }

    /// Test seam: marks a key as recently failed, exactly as a capture failure
    /// does. Lets a test lock down the contract the views rely on — a window
    /// that cannot be captured reports failure instead of re-arming a spinner.
    func markFailedForTesting(window: WindowInfo, tier: ThumbnailTier, error: Error = ThumbnailError.captureFailed) {
        markFailed(ThumbnailCacheKey(window.id, tier), error: error)
    }

    /// Test seam: number of entries currently under a given tier. Lets a test
    /// assert tier isolation without depending on `entries`'s layout.
    func entryCountForTesting(tier: ThumbnailTier) -> Int {
        lock.lock()
        let count = tierCounts[tier] ?? 0
        lock.unlock()
        return count
    }

    /// 模拟系统在内存压力下清理 NSCache，不改动元数据记账。
    func purgeImagesForTesting() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }

    /// Test seam: the merged auto-refresh interest for one tier — the union of
    /// every registered surface's window IDs.
    func refreshInterestForTesting(tier: ThumbnailTier) -> Set<CGWindowID> {
        lock.lock()
        let merged = interestedWindowIDsLocked(tier: tier)
        lock.unlock()
        return merged
    }

    /// Test seam: seconds of failure cooldown remaining for a key
    /// (0 when none is active).
    func failureCooldownRemainingForTesting(window: WindowInfo, tier: ThumbnailTier) -> TimeInterval {
        let key = ThumbnailCacheKey(window.id, tier)
        lock.lock()
        let blockedUntil = failedUntil[key]
        lock.unlock()
        guard let blockedUntil else {
            return 0
        }
        return max(0, blockedUntil.timeIntervalSinceNow)
    }

    // MARK: - Capture helpers

    private func recordCaptureSize(_ pixelSize: CGSize, tier: ThumbnailTier) {
        guard pixelSize.width > 1, pixelSize.height > 1 else {
            return
        }
        lock.lock()
        lastCaptureSize[tier] = pixelSize
        lock.unlock()
    }

    /// Records window identity on every attempt, successful or not.
    ///
    /// The auto-refresh tick rebuilds a `WindowInfo` from this table before
    /// re-capturing, and `store` used to be the only writer. A window whose
    /// first capture failed therefore had no metadata, so the tick skipped it
    /// forever: nothing ever retried it and the preview stayed broken until the
    /// user reopened the panel.
    private func recordWindowMeta(_ window: WindowInfo) {
        lock.lock()
        windowMeta[window.id] = WindowMetadata(
            ownerPID: window.ownerPID,
            ownerName: window.ownerName,
            title: window.windowTitle,
            bounds: window.bounds,
            isOnCurrentSpace: window.isOnCurrentSpace,
            recordedAt: Date()
        )
        pruneWindowMetaLocked()
        lock.unlock()
    }

    /// Caps `windowMeta`. The table used to be append-only: every window ever
    /// captured left a record behind, and nothing removed records for closed
    /// windows — a long session grew it without bound (slowly, but without
    /// limit). Live panels re-publish their windows' metadata on every
    /// capture, so dropping stale records cannot evict anything a visible
    /// panel still needs.
    private func pruneWindowMetaLocked() {
        guard windowMeta.count > 256 else {
            return
        }
        let ranked = windowMeta.sorted { $0.value.recordedAt < $1.value.recordedAt }
        for (id, _) in ranked.prefix(windowMeta.count - 192) {
            windowMeta.removeValue(forKey: id)
        }
    }

    /// Whether this key failed a capture recently enough that we are still
    /// holding off (see `failureCooldown`).
    ///
    /// Views use it to show an honest failure state instead of re-arming a
    /// loading spinner for a window we just proved we cannot capture right now,
    /// and it keeps them from hammering the window server in the meantime. The
    /// background tick retries once the cooldown expires.
    func failedRecently(for window: WindowInfo, tier: ThumbnailTier) -> Bool {
        let key = ThumbnailCacheKey(window.id, tier)
        lock.lock()
        let blockedUntil = failedUntil[key]
        lock.unlock()
        guard let blockedUntil else {
            return false
        }
        return blockedUntil > Date()
    }

    /// Backing scale used to turn a point request into bitmap pixels.
    ///
    /// All preview surfaces open on the screen the user is working on, so
    /// `NSScreen.main` is a good approximation. On a mixed-DPI multi-monitor
    /// setup the previewed screen may have a different scale than `NSScreen.main`
    /// reports; the consequence is a sharper or softer thumbnail, never a
    /// wrong one.
    static var displayScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2.0
    }

    /// Converts a logical (points) request into real bitmap pixels, then clamps
    /// it to the tier's cap.
    ///
    /// The cap matters for the native tier: a window the size of a 6K display is
    /// a 325 MB bitmap at 2x, three times the tier's whole 128 MB envelope, so
    /// it would evict itself on every store and the replica would never keep an
    /// image. The clamp is aspect preserving so the preview is softer, never
    /// distorted.
    static func pixelSize(forPoints size: CGSize, scale: CGFloat, tier: ThumbnailTier) -> CGSize {
        let scale = scale > 0 ? scale : 1
        let requested = CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )

        guard let cap = tier.maxPixelSize, cap.width > 1, cap.height > 1,
              requested.width > cap.width || requested.height > cap.height else {
            return requested
        }

        let factor = min(cap.width / requested.width, cap.height / requested.height)
        return CGSize(
            width: max(1, (requested.width * factor).rounded()),
            height: max(1, (requested.height * factor).rounded())
        )
    }

    private func captureWindowThumbnail(_ window: WindowInfo, pixelSize: CGSize, scale: CGFloat) throws -> CapturedThumbnail {
        guard screenCaptureAccess() else {
            AppLogger.error("Screen capture permission is not granted. Cannot capture thumbnail. windowID=\(window.id), owner=\(window.ownerName)")
            throw ThumbnailError.screenCapturePermissionDenied
        }

        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]

        // `CGWindowListCreateImage` can block indefinitely when the macOS
        // ScreenCaptureKit proxying layer is stuck (observed on macOS 26: the
        // call sits on `semaphore_timedwait_trap` forever). Run the call on a
        // background queue and wait with a hard timeout so a single bad
        // capture cannot pin a worker thread and freeze the dock cards.
        //
        // `.null` captures the whole window at the display's native pixel
        // resolution regardless of the size we ultimately want, so this call's
        // cost does not depend on `pixelSize`; only the downscale below does.
        var captured: CGImage?
        let semaphore = DispatchSemaphore(value: 0)
        let captureQueue = DispatchQueue.global(qos: .userInitiated)
        let windowID = window.id
        captureQueue.async {
            let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                options
            )
            if let image {
                captured = image
            }
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + captureTimeout)
        if waitResult == .timedOut {
            AppLogger.error("CGWindowListCreateImage timed out after \(captureTimeout)s. windowID=\(window.id), owner=\(window.ownerName)")
            // Distinct from a plain failure: timed-out attempts leak the
            // global-queue thread they were dispatched to, so `markFailed`
            // escalates the cooldown for them — see `timeoutStrikes`.
            throw ThumbnailError.captureTimedOut
        }

        guard let cgImage = captured else {
            AppLogger.throttledError(
                key: "capture:\(window.id)",
                "Failed to capture window thumbnail. windowID=\(window.id), owner=\(window.ownerName), title=\(window.windowTitle), bounds=\(window.bounds)"
            )
            throw ThumbnailError.captureFailed
        }

        if isBlankImage(cgImage) {
            AppLogger.warning("Captured blank thumbnail (window content not ready). windowID=\(window.id), owner=\(window.ownerName)")
            throw ThumbnailError.blankCapture
        }

        return try makeThumbnail(from: cgImage, pixelSize: pixelSize, scale: scale)
    }

    /// ScreenCaptureKit fallback for windows the CG capture API cannot read
    /// (e.g. remote-desktop / OpenGL content that returns blank). Available on
    /// macOS 14+. Uses the same screen-recording permission already required
    /// by the CG path.
    ///
    /// Wrapped in a `Task` with a hard timeout because SCK can also hang on the
    /// same system-level stall that makes `CGWindowListCreateImage`
    /// block forever on macOS 26.
    private func captureWithScreenCaptureKit(window: WindowInfo, pixelSize: CGSize, scale: CGFloat) async -> CapturedThumbnail? {
        guard #available(macOS 14.0, *),
              screenCaptureAccess() else {
            return nil
        }

        // Minimized windows have no on-screen content; SCK cannot capture them.
        guard window.isOnCurrentSpace else {
            return nil
        }

        return await withTaskGroup(of: CapturedThumbnail?.self, returning: CapturedThumbnail?.self) { group in
            group.addTask { [weak self] in
                await self?.performSCKCapture(window: window, pixelSize: pixelSize, scale: scale) ?? nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.sckCaptureTimeout * 1_000_000_000))
                return nil
            }
            // Whichever finishes first wins. If the timeout task wins, we
            // return nil and the SCK task continues running in the background
            // (it will eventually return or hang; either way the dock card
            // has already moved on).
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @available(macOS 14.0, *)
    private func performSCKCapture(window: WindowInfo, pixelSize: CGSize, scale: CGFloat) async -> CapturedThumbnail? {
        // Resolve the CG window ID to an SCWindow. `SCShareableContent.current`
        // is slow on some systems, so this stays on the fallback path only.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            AppLogger.warning("SCK fallback: cannot list shareable content. windowID=\(window.id), error=\(error)")
            return nil
        }

        guard let scWindow = content.windows.first(where: {
            $0.windowID == window.id && $0.owningApplication?.processID == window.ownerPID
        }) else {
            AppLogger.warning("SCK fallback: window not found in shareable content. windowID=\(window.id)")
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        // `pixelSize` is already in device pixels, so it configures the stream
        // directly (the old code multiplied the point size by 2 here).
        configuration.width = max(1, Int(pixelSize.width))
        configuration.height = max(1, Int(pixelSize.height))
        configuration.showsCursor = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            AppLogger.info("SCK fallback captured thumbnail. windowID=\(window.id), size=\(cgImage.width)x\(cgImage.height)")
            return try makeThumbnail(from: cgImage, pixelSize: pixelSize, scale: scale)
        } catch {
            AppLogger.warning("SCK fallback capture failed. windowID=\(window.id), error=\(error)")
            return nil
        }
    }

    /// Fits a captured image into `pixelSize` while preserving aspect ratio, and
    /// actually resamples the bitmap.
    ///
    /// This is where the memory saving lives. `CGWindowListCreateImage` hands
    /// back the window at its native pixel size (a 1744x1000 pt window on a 2x
    /// display is 3488x2000 px ≈ 27 MB), of which a grid tile needs ~0.5 MB.
    /// Declaring a smaller `NSImage.size` — the previous behaviour — kept the
    /// full-resolution bitmap alive behind a small logical size.
    ///
    /// Upscaling is deliberately skipped: a window smaller than the target would
    /// only waste memory and add interpolation blur.
    private func makeThumbnail(from cgImage: CGImage, pixelSize: CGSize, scale: CGFloat) throws -> CapturedThumbnail {
        let source = CGSize(width: cgImage.width, height: cgImage.height)
        let fitted = Self.fittedPixelSize(source: source, into: pixelSize)
        let targetWidth = max(1, Int(fitted.width.rounded()))
        let targetHeight = max(1, Int(fitted.height.rounded()))

        let bitmap: CGImage
        if targetWidth >= cgImage.width && targetHeight >= cgImage.height {
            bitmap = cgImage
        } else if let downsampled = Self.downsample(cgImage, width: targetWidth, height: targetHeight) {
            bitmap = downsampled
        } else {
            AppLogger.warning("Downsampling failed; keeping native bitmap. source=\(source), target=\(pixelSize)")
            bitmap = cgImage
        }

        // Declare the logical size that matches the bitmap at the display's
        // pixel scale so SwiftUI never re-scales the representation. `scale`
        // was captured on the main thread by the caller — this function runs
        // on capture queues and Task executors, where reading `NSScreen` is
        // undefined AppKit behaviour (the old code did exactly that).
        let logicalScale = scale > 0 ? scale : 1
        let logicalSize = CGSize(
            width: CGFloat(bitmap.width) / logicalScale,
            height: CGFloat(bitmap.height) / logicalScale
        )
        return CapturedThumbnail(
            image: NSImage(cgImage: bitmap, size: logicalSize),
            // Report the bitmap we actually produced, not the size we asked
            // for. They differ whenever the window is smaller than the target
            // (upscaling is skipped) or when downsampling failed, and the cache
            // byte accounting must follow the real allocation.
            pixelSize: CGSize(width: bitmap.width, height: bitmap.height)
        )
    }

    /// Aspect-preserving fit of `source` into `box`, never larger than `source`.
    static func fittedPixelSize(source: CGSize, into box: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else {
            return source
        }
        let sourceAspect = source.width / source.height
        let boxAspect = box.width / box.height

        let fitted: CGSize
        if sourceAspect > boxAspect {
            fitted = CGSize(width: box.width, height: (box.width / sourceAspect).rounded())
        } else {
            fitted = CGSize(width: (box.height * sourceAspect).rounded(), height: box.height)
        }

        if fitted.width >= source.width || fitted.height >= source.height {
            return source
        }
        return fitted
    }

    /// Real bitmap resampling. Measured at 0.5–3 ms for a 4K source, i.e. noise
    /// next to the WindowServer round trip.
    static func downsample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else {
            return nil
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            // Opaque capture: skip the alpha channel. Still 4 bytes per pixel,
            // but avoids a per-pixel blend during the draw.
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Detects captures whose content is essentially uniform (blank white,
    /// blank black, or fully transparent) — e.g. an app window whose backing
    /// store has not been rendered yet. Downsampled luminance variance check.
    private func isBlankImage(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return true }

        let sampleWidth = min(32, width)
        let sampleHeight = min(32, height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &buffer,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var sum: Int = 0
        var sumSquared: Int = 0
        var count = 0
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Int(buffer[index + 3])
            guard alpha >= 16 else { continue }
            let luminance = (Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])) / 3
            sum += luminance
            sumSquared += luminance * luminance
            count += 1
        }
        // Fully transparent → nothing rendered → blank.
        guard count > 0 else { return true }

        let mean = sum / count
        let variance = sumSquared / count - mean * mean
        // Blank when there is almost no variance AND the content is uniformly
        // near-white or near-black (unrendered backing store).
        return variance < 120 && (mean > 240 || mean < 16)
    }

    // MARK: - Preheat gating

    /// 45 秒后可后台刷新。小图的新鲜度与 24 小时兜底有效期分开计时；
    /// 放大预览仍使用原有 60 秒有效期，刷新在过期之前发生。
    private var refreshAgeThreshold: TimeInterval {
        cacheExpiration * 0.75
    }

    /// 检查缓存与退避，并在同一把锁内占用捕获任务，防止并发预热重复排队。
    func claimPreheat(windowID: CGWindowID, tier: ThumbnailTier) -> Bool {
        let key = ThumbnailCacheKey(windowID, tier)
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        if inFlightKeys.contains(key) {
            return false
        }

        if let entry = entries[key],
           now.timeIntervalSince(entry.timestamp) < refreshAgeThreshold {
            return false
        }

        if let blockedUntil = failedUntil[key],
           blockedUntil > now {
            return false
        }

        inFlightKeys.insert(key)
        return true
    }

    /// Claims the in-flight slot for a key; returns false when another
    /// attempt (preheat or another view's on-demand capture) is already
    /// running. The caller should then await `waitUntilCaptureFinishes` and
    /// read the cache, instead of starting a duplicate capture pipeline.
    private func claimInFlight(_ key: ThumbnailCacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlightKeys.contains(key) {
            return false
        }
        inFlightKeys.insert(key)
        return true
    }

    /// Suspends until the in-flight attempt for `key` finishes. Waiters are
    /// continuations — never blocked threads — resumed by `markFinished`.
    private func waitUntilCaptureFinishes(_ key: ThumbnailCacheKey) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !inFlightKeys.contains(key) {
                lock.unlock()
                continuation.resume()
                return
            }
            inFlightWaiters[key, default: []].append(continuation)
            lock.unlock()
        }
    }

    private func markFinished(_ key: ThumbnailCacheKey) {
        lock.lock()
        inFlightKeys.remove(key)
        let waiters = inFlightWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Records a capture failure. Timeouts escalate: every consecutive CG
    /// timeout doubles the cooldown (8 s → 16 s → … → 600 s), because each
    /// timed-out attempt has already leaked the global-queue thread it ran
    /// on — an unthrottled retry loop against a hung window server call
    /// accumulates threads until the process runs out of them.
    private func markFailed(_ key: ThumbnailCacheKey, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        let cooldown: TimeInterval
        if let thumbnailError = error as? ThumbnailError,
           case .captureTimedOut = thumbnailError {
            let strikes = timeoutStrikes[key, default: 0] + 1
            timeoutStrikes[key] = strikes
            cooldown = min(failureCooldown * pow(2, Double(strikes - 1)), maxFailureCooldown)
        } else {
            cooldown = failureCooldown
        }

        failedUntil[key] = Date().addingTimeInterval(cooldown)
    }

    // MARK: - Capture admission

    /// Suspends until a capture-pipeline slot is free — see
    /// `maxConcurrentCaptures`. Waiters are FIFO continuations, never
    /// blocked threads.
    private func waitForCaptureSlot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activeCaptureCount < Self.maxConcurrentCaptures {
                activeCaptureCount += 1
                lock.unlock()
                continuation.resume()
                return
            }
            captureAdmissionWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func releaseCaptureSlot() {
        lock.lock()
        activeCaptureCount -= 1
        var next: CheckedContinuation<Void, Never>?
        if !captureAdmissionWaiters.isEmpty {
            next = captureAdmissionWaiters.removeFirst()
            activeCaptureCount += 1
        }
        lock.unlock()
        next?.resume()
    }

    private func captureAndCache(window: WindowInfo, key: ThumbnailCacheKey, pixelSize: CGSize, scale: CGFloat, reason: String) {
        defer {
            markFinished(key)
        }

        do {
            recordWindowMeta(window)
            let captured = try awaitAttempt(window: window, pixelSize: pixelSize, scale: scale, tier: key.tier)
            // Only the auto-refresh tick suppresses the crossfade; event-
            // driven preheat keeps it so a freshly opened panel still fades
            // its first frames in.
            let animated = reason != "auto-refresh"
            store(captured.image, key: key, window: window, pixelSize: captured.pixelSize, animated: animated)
            AppLogger.verbose("Preheated thumbnail. reason=\(reason), \(key.description)")
        } catch {
            markFailed(key, error: error)
            AppLogger.throttledWarning(
                key: "preheat:\(key.description)",
                "Failed to preheat thumbnail. reason=\(reason), \(key.description), error=\(error)"
            )
            // Failure is announced the same way success is, with a flag, so a
            // consumer that is waiting for an image (the replica) can stop
            // waiting and show its fallback instead of pulsing forever. The
            // grid cards ignore the flag: they never find an image in the cache
            // for a failed key and no-op.
            notifyThumbnailDidUpdate(windowID: key.windowID, tier: key.tier, animated: false, failed: true)
        }
    }
}

/// A thumbnail as produced by the capture path: the image plus the resolution
/// of the bitmap that is actually backing it.
///
/// Capture is *not* guaranteed to honour the requested size — a window smaller
/// than the target is kept at native resolution (upscaling is skipped), and a
/// failed downsample also falls back to native. Carrying the real size here is
/// what keeps the cache byte budget and `storedPixelSize` honest.
private struct CapturedThumbnail {
    let image: NSImage
    let pixelSize: CGSize
}

/// How much one tier may keep resident.
///
/// The tiers are budgeted **independently** rather than sharing one pool,
/// because their cardinalities and their per-entry sizes differ by orders of
/// magnitude. Measured byte sizes for one entry (4 bytes per pixel, the format
/// the capture path produces):
///
/// | tier   | entry size                      | how many are live at once |
/// |--------|---------------------------------|---------------------------|
/// | grid   | 400 KB (400x250)                | every open window         |
/// | native | 31.6 MB (1920x1080 pt @2x)      | one — the selected window |
/// | native | 77.7 MB (6016x3384 @2x, 6K XDR) | one                       |
///
/// A shared 64 MB pool therefore holds either ~167 grid thumbnails **or** two
/// native bitmaps, and a single native capture would evict the whole grid
/// cache. Separate envelopes keep the grid cache intact while the enlarged
/// preview is open.
///
/// Measured evidence that the limits cannot be left to `NSCache`: with its
/// `totalCostLimit = 1 MB`, inserting 20 objects of 576 KB each (11.5 MB total)
/// through `setObject(_:forKey:cost:)` left all 20 alive both immediately and
/// after 550 ms, and `countLimit` behaved the same way. So these limits are
/// enforced synchronously by `ThumbnailService`, which also makes them
/// assertable in unit tests.
struct TierBudget {
    let byteLimit: Int
    let countLimit: Int

    /// Grid / list thumbnails: small, numerous, latency-sensitive. Sized so the
    /// full grid of a busy workspace stays resident across panel opens.
    static let grid = TierBudget(byteLimit: 64 * 1024 * 1024, countLimit: 200)

    /// The window replica's bitmap: one window at its own size, in display
    /// pixels. Deliberately a single slot: the replica only ever replays one
    /// window, re-capturing is required whenever the highlighted window changes
    /// anyway, and the only reuse is flipping back and forth between two
    /// windows. One slot caps the cost at exactly one window-sized bitmap
    /// (31.6 MB for a display-filling window at 1080p/2x, 77.7 MB at the 6K/2x
    /// cap). The byte limit sits above the largest display that exists today so
    /// the slot is never self-evicting.
    static let native = TierBudget(byteLimit: 128 * 1024 * 1024, countLimit: 1)
}

/// Window identity recorded alongside each cached thumbnail. Size independent:
/// it is the same for every tier, and it is what the auto-refresh tick needs to
/// rebuild a `WindowInfo` without re-querying the window server.
private struct WindowMetadata {
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
    let isOnCurrentSpace: Bool
    /// When this record was last written. The table used to grow without
    /// bound (nothing removed records for closed windows); records are now
    /// pruned by age once it passes its cap.
    let recordedAt: Date
}

/// One cached thumbnail for a (window, tier) pair.
private struct ThumbnailEntry {
    let ownerPID: pid_t
    let title: String
    let cost: Int
    let pixelSize: CGSize
    let timestamp: Date
}

enum ThumbnailError: LocalizedError {
    case captureFailed
    /// The CG capture was abandoned after `captureTimeout`. Distinct from
    /// `captureFailed` because timed-out attempts leak the thread they were
    /// dispatched to, which the failure cooldown escalates on — see
    /// `ThumbnailService.timeoutStrikes`.
    case captureTimedOut
    case screenCapturePermissionDenied
    case blankCapture

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            return NSLocalizedString("Failed to capture window thumbnail", comment: "")
        case .captureTimedOut:
            return NSLocalizedString("Capturing the window timed out", comment: "")
        case .screenCapturePermissionDenied:
            return NSLocalizedString("Screen capture permission is not granted", comment: "")
        case .blankCapture:
            return NSLocalizedString("Window content is not ready to capture", comment: "")
        }
    }
}

extension Notification.Name {
    static let thumbnailDidUpdate = Notification.Name("com.switchly.thumbnailDidUpdate")
}
