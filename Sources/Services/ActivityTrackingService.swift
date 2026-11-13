import AppKit
import Combine
import CoreGraphics

@MainActor
protocol ActivityTracking: AnyObject {
    func apply(_ settings: ActivityTrackingSettings)
    func clear() async
    func stop()
}

@MainActor
final class ActivityTrackingService: ObservableObject, ActivityTracking {
    @Published private(set) var revision = 0
    @Published private(set) var errorKey: String?
    @Published private(set) var isClearing = false
    private(set) var settings = ActivityTrackingSettings()
    let store: ActivityStore
    let snapshots: ActivitySnapshotStore
    let validity = PluginActivityValidityGate()
    private(set) var generation = UUID() { didSet { validity.invalidate() } }
    private let tracker: AppActivationTracker
    private let capturer: RawWindowCapturing
    private var machine = ActivityTrackingMachine()
    private var activationID: UUID?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var systemSleeping = false
    private var displaySleeping = false
    private var explicitlyLocked = false
    private var inactive = false
    private var pending: [UUID: ActivitySession] = [:]
    private var truncateAfter: Date?
    private var lastFlush: TimeInterval = 0
    private struct WriteBatch {
        let sessions: [ActivitySession]
        let cutoff: Date?
        let retention: Int
        let generation: UUID
    }
    private var failedWrites: [WriteBatch] = []
    private var writeTail: Task<Void, Never>?
    private var captureID: UUID?
    private var captureTask: Task<Void, Never>?
    private var lastCapture: [String: TimeInterval] = [:]
    private var lastAttempt: TimeInterval = -.infinity
    private let uptime: () -> TimeInterval

    init(store: ActivityStore, snapshots: ActivitySnapshotStore, tracker: AppActivationTracker,
         capturer: RawWindowCapturing = RawWindowCaptureService(),
         uptime: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) {
        self.store = store; self.snapshots = snapshots; self.tracker = tracker
        self.capturer = capturer; self.uptime = uptime
        let token = generation
        writeTail = Task {
            do { try await store.begin(generation: token); await snapshots.begin(generation: token) }
            catch { AppLogger.error("Activity store initialization failed") }
        }
    }

    func apply(_ settings: ActivityTrackingSettings) {
        let previous = self.settings
        self.settings = settings
        if settings.enabled && timer == nil { start() }
        if previous.screenshotsEnabled != settings.screenshotsEnabled || previous.screenshotBundleIDs != settings.screenshotBundleIDs || previous.excludedBundleIDs != settings.excludedBundleIDs {
            captureTask?.cancel()
            invalidate()
        }
        tick()
        if !settings.enabled { detach(); flush() }
        let previousWrite = writeTail
        writeTail = Task { [weak self, store, snapshots] in
            await previousWrite?.value
            do {
                try await store.prune(retentionDays: settings.resolvedRetentionDays)
                try await snapshots.prune(retentionDays: settings.resolvedScreenshotRetentionDays)
            } catch { self?.fail() }
        }
    }

    private func start() {
        activationID = tracker.subscribe { [weak self] _ in Task { @MainActor in self?.tick() } }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemSleeping = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaySleeping = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaySleeping = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.inactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.inactive = false }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { _ in }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.explicitlyLocked = true }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.explicitlyLocked = false }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 1
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (ActivityTrackingService) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; change(self); self.tick(); self.flush()
            }
        }
        observers.append((center, token))
    }
    private func blockers() -> Set<ActivityBlocker> {
        var blocked = Set<ActivityBlocker>()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if explicitlyLocked || session?["CGSSessionScreenIsLocked"] as? Bool == true { blocked.insert(.locked) }
        if systemSleeping || displaySleeping { blocked.insert(.sleeping) }
        if inactive || session == nil || session?[kCGSessionOnConsoleKey as String] as? Bool == false { blocked.insert(.inactiveSession) }
        return blocked
    }
    private func frontmost() -> ActivityApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              !settings.excludedBundleIDs.contains(id), app.activationPolicy == .regular else { return nil }
        return ActivityApp(bundleID: id, name: app.localizedName ?? id)
    }
    private func tick() {
        guard !isClearing else { return }
        let now = Date(), mono = uptime(), blocked = blockers()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let result = machine.update(app: frontmost(), at: now, uptime: mono, idleSeconds: idle, blockers: blocked, enabled: settings.enabled)
        for session in result.sessions where session.end > session.start { pending[session.id] = session }
        if let cutoff = result.truncateAfter {
            truncateAfter = min(truncateAfter ?? cutoff, cutoff)
            captureTask?.cancel()
        }
        if !result.sessions.isEmpty || result.truncateAfter != nil { invalidate() }
        if result.truncateAfter != nil || mono - lastFlush >= 30 || !blocked.isEmpty { flush(); lastFlush = mono }
        if blocked.isEmpty && idle < 300 { sampleScreenshot(at: mono) }
        else { captureTask?.cancel() }
    }
    func flush() {
        guard !pending.isEmpty || truncateAfter != nil || !failedWrites.isEmpty else { return }
        let batch = WriteBatch(sessions: Array(pending.values), cutoff: truncateAfter, retention: settings.resolvedRetentionDays, generation: generation)
        let previous = writeTail
        pending.removeAll(); truncateAfter = nil
        writeTail = Task { [weak self, store] in
            await previous?.value
            guard let self, self.generation == batch.generation else { return }
            let batches = self.failedWrites + [batch]
            self.failedWrites.removeAll()
            for (index, current) in batches.enumerated() {
                do {
                    try await store.apply(current.sessions, truncateAfter: current.cutoff, retentionDays: current.retention, generation: current.generation)
                } catch {
                    guard self.generation == batch.generation else { return }
                    self.failedWrites = Array(batches[index...])
                    // 磁盘故障期间保留有界重放队列；沿用100000段的最旧淘汰预算。
                    while self.failedWrites.count > 1000 || self.failedWrites.reduce(0, { $0 + $1.sessions.count }) > ActivityStore.maximumSessions { self.failedWrites.removeFirst() }
                    self.fail(); return
                }
            }
            if self.generation == batch.generation { self.errorKey = nil }
        }
    }
    func flushAndWait() async { flush(); await writeTail?.value }

    func clear() async {
        guard !isClearing else { return }
        isClearing = true
        captureTask?.cancel()
        let previous = writeTail, old = generation, next = UUID()
        generation = next; machine = ActivityTrackingMachine(); pending.removeAll(); failedWrites.removeAll(); truncateAfter = nil
        lastCapture.removeAll(); invalidate()
        let task = Task { [weak self, store, snapshots] in
            await previous?.value
            var failed = false
            do { try await store.clear(generation: old) } catch { failed = true }
            // 清除中途I/O失败也要恢复新代次，允许用户重试，不能永久卡住旧token。
            do { try await store.begin(generation: next) } catch { failed = true }
            do { try await snapshots.clear(generation: next) } catch { failed = true }
            if failed { self?.fail() } else { self?.errorKey = nil }
        }
        writeTail = task; await task.value
        isClearing = false; invalidate(); tick()
    }
    func stop() {
        settings.enabled = false; tick(); flush(); detach()
    }
    private func detach() {
        if let activationID { tracker.unsubscribe(activationID) }; activationID = nil
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        timer?.invalidate(); timer = nil
        captureTask?.cancel()
    }
    private func fail() { errorKey = "Activity data could not be saved. Check available disk space and try again."; invalidate() }
    private func invalidate() { revision &+= 1; NotificationCenter.default.post(name: .activityDataDidChange, object: self, userInfo: ["generation": generation]) }

    private func sampleScreenshot(at mono: TimeInterval) {
        // 全局至少间隔30秒，仅保留10分钟内的成功采样，最多约20个条目。
        lastCapture = lastCapture.filter { mono - $0.value < 600 }
        guard settings.enabled, settings.screenshotsEnabled, CGPreflightScreenCaptureAccess(), captureTask == nil,
              let current = machine.current, current.seconds >= 30,
              settings.screenshotBundleIDs.contains(current.bundleID),
              mono - (lastCapture[current.bundleID] ?? -.infinity) >= 600, mono - lastAttempt >= 30,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == current.bundleID,
              // 与 RawWindowCaptureService 使用同一内核身份；AppKit launchDate
              // 在实机上可相差数毫秒，混用会令有效窗口被判为进程已更换。
              let launched = WindowCaptureProcessIdentity.startedAt(pid: app.processIdentifier) else { return }
        lastAttempt = mono
        let token = generation, pid = app.processIdentifier, bundle = current.bundleID
        let job = UUID(); captureID = job
        captureTask = Task { [weak self, capturer, snapshots] in
            defer { if self?.captureID == job { self?.captureTask = nil; self?.captureID = nil } }
            do {
                let windowID = await Task.detached(priority: .utility) { Self.visibleFocusedWindowID(for: pid) }.value
                guard let windowID else {
                    AppLogger.debug("Activity screenshot skipped. reason=focusedWindowUnavailable")
                    return
                }
                guard let self, self.captureIsCurrent(current, token: token, pid: pid) else { return }
                let target = WindowCaptureTarget(windowID: windowID, pid: pid, processStartedAt: launched)
                let image = try await capturer.capture(target: target)
                let stillFocused = await Task.detached(priority: .utility) { Self.visibleFocusedWindowID(for: pid) }.value
                try Task.checkCancellation()
                guard stillFocused == windowID, self.captureIsCurrent(current, token: token, pid: pid) else { return }
                try await snapshots.save(image, session: current, generation: token, retentionDays: self.settings.resolvedScreenshotRetentionDays)
                guard self.generation == token else { return }
                // 冷却从成功落盘完成时开始，不能把 AX／抓取／压缩耗时抵扣。
                self.lastCapture[bundle] = self.uptime()
                self.invalidate()
                AppLogger.debug("Activity screenshot saved")
            } catch {
                // 仅记录稳定原因码，不记录应用、路径、标题或屏幕内容。
                let reason = (error as? WindowCaptureFailure)?.rawValue
                    ?? (error is CancellationError ? "cancelled" : "storageFailed")
                AppLogger.debug("Activity screenshot skipped. reason=\(reason)")
            }
        }
    }
    private nonisolated static func visibleFocusedWindowID(for pid: Int32) -> CGWindowID? {
        guard let id = AccessibilityService.shared.focusedWindowID(for: pid, allowCGFallback: false),
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              info.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                  ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true &&
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }) else { return nil }
        return id
    }

    private func captureIsCurrent(_ session: ActivitySession, token: UUID, pid: Int32) -> Bool {
        generation == token && !isClearing && settings.enabled && settings.screenshotsEnabled &&
        !settings.excludedBundleIDs.contains(session.bundleID) && settings.screenshotBundleIDs.contains(session.bundleID) &&
        blockers().isEmpty && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) < 300 && machine.current?.id == session.id &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && CGPreflightScreenCaptureAccess()
    }
}

extension Notification.Name {
    static let activityDataDidChange = Notification.Name("com.switchly.activityDataDidChange")
}
