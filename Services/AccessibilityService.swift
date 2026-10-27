//
//  AccessibilityService.swift
//  Switchly
//
//  Service for managing accessibility permissions and interacting with system windows
//
//  ## How a target window is identified
//
//  Switching to a window is a two-step operation: activate the owning
//  application, then bring *one specific* window of it to the front. The second
//  step needs to map a CoreGraphics window (what the preview card was built
//  from) onto an Accessibility window element (what can be raised), and that
//  mapping is the hard part:
//
//  - The private `AXWindowNumber` attribute would give an exact answer, but it
//    is missing from most apps in practice (measured: nil in 116 of 116 real
//    switches, including for apps such as PyCharm that expose other AX
//    attributes).
//  - Titles cannot be trusted either: apps routinely report a different string
//    through AX than through CG (Chrome reports
//    `新标签页 - Google Chrome - alice` while CG reports `新标签页`), so strict
//    equality fails and identification silently degrades to geometry alone.
//  - Geometry alone is ambiguous exactly when it matters: several maximized
//    windows of one app share identical bounds and score identically, so
//    whichever candidate the tie-break picks is arbitrary — and because the
//    raise *does* succeed, verification passes and the wrong window comes
//    forward. That is the multi-window "click does nothing" bug.
//
//  The pipeline here is therefore ordered from authoritative to heuristic, and
//  then backed by a search:
//
//  1. exact `AXWindowNumber` (when an app exposes it),
//  2. an exact title match combined with matching geometry,
//  3. z-order correlation (see `zOrderMatchedAXWindow`) — used whenever the
//     scored candidates are not decisive, which is the multi-window case: a
//     Chromium app whose AX and CG titles never agree, or several windows that
//     are identical in title *and* geometry. Their relative front-to-back order
//     is still unique, and CG always enumerates front-to-back,
//  4. the remaining scored candidates, best first,
//  5. the single-standard-window fallback,
//  6. if none of the above verifiably raises the requested window, every
//     remaining Accessibility window of the app is probed one at a time
//     (`resolveAndFocus`).
//
//  Step 6 is what makes the mechanism self-correcting. Heuristics 1–5 are all
//  predictions, and any of them can be wrong for some app; predicting harder
//  cannot fix a wrong prediction. Because every attempt ends with a
//  CoreGraphics check of what is actually in front, a wrong guess is *detected*
//  and costs one bounded attempt instead of failing the switch — which is what
//  made the multi-window case unrecoverable before: the wrong window was raised
//  and the Accessibility API agreed, so the switch reported success.
//
//  Success is always judged by CoreGraphics — the layer the user actually sees —
//  never by the Accessibility API reporting back what we just set.
//

import Foundation
import AppKit

/// One possible Accessibility element for a requested window, in preference
/// order. `reason` is recorded in the log so a failed switch can be explained
/// without re-running it.
struct WindowFocusCandidate {
    let element: AXUIElement
    let reason: String
    let needsUnminimize: Bool
}

protocol AccessibilityServiceProtocol {
    var isPermissionGranted: Bool { get }
    func requestPermission()
    func checkPermissionStatus() -> Bool
    func openAccessibilityPreferences()
    func bringWindowToFront(_ windowID: CGWindowID) -> Bool
    func bringWindowToFront(_ window: WindowInfo) -> Bool
    func windowCandidates(for window: WindowInfo) -> [WindowFocusCandidate]
    func allAXWindows(for pid: pid_t) -> [AXUIElement]
    func resolveAndFocus(_ window: WindowInfo) -> Bool
    func focus(candidate: WindowFocusCandidate, window: WindowInfo) -> Bool
    func isFrontmostOnScreen(_ window: WindowInfo) -> Bool
    func setWindowPosition(_ windowID: CGWindowID, frame: CGRect) -> Bool
    func listAllWindows() -> [CGWindowID]
}

class AccessibilityService: AccessibilityServiceProtocol {
    static let shared = AccessibilityService()

    /// Windows smaller than this are chrome/utility surfaces rather than user
    /// windows and are ignored everywhere (the window monitor applies the same
    /// rule, so the two orderings describe the same set of windows).
    private static let minimumWindowWidth: CGFloat = 80
    private static let minimumWindowHeight: CGFloat = 60

    /// How many times the raise is re-applied when a window reaches the front
    /// and is then replaced again by its own application.
    private static let maxRaiseAttempts = 3

    /// Upper bound on raise+verify attempts for a single switch, shared by the
    /// heuristic candidates and the probe fallback. Bounded so that a window
    /// which cannot be raised at all still returns quickly instead of stalling
    /// the caller: worst case is the activation wait plus
    /// `maxFocusAttempts` × `frontmostSampleCount` × `frontmostSampleInterval`
    /// ≈ 1.2 s.
    private static let maxFocusAttempts = 5

    /// Frontmost sampling after a raise: 5 × 60 ms = 300 ms per attempt, long
    /// enough to notice an app that re-asserts its own key window after
    /// activation (Chromium does).
    private static let frontmostSampleCount = 5
    private static let otherSpaceSampleCount = 25
    private static let frontmostSampleInterval: TimeInterval = 0.06
    /// Extra wait after a failed verification: a desktop switch (animation plus
    /// a slow app) can complete after `otherSpaceSampleCount` samples have run
    /// out, and reporting that as a failure shows an error for a switch that
    /// actually happened.
    private static let lateFrontGraceSampleCount = 20

    /// Score of an exact title match combined with matching size and position:
    /// the strongest evidence available, and the point above which scoring is
    /// allowed to outrank z-order correlation.
    private static let decisiveTitleScore = 40 + 25 + 20

    private init() {}

    var isPermissionGranted: Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: false]
        let granted = AXIsProcessTrustedWithOptions(options)
        AppLogger.debug("Checked accessibility permission. granted=\(granted)")
        return granted
    }

    func requestPermission() {
        AppLogger.info("Requesting accessibility permission prompt")
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func checkPermissionStatus() -> Bool {
        return isPermissionGranted
    }

    func openAccessibilityPreferences() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            AppLogger.error("Failed to create accessibility preferences URL")
            return
        }
        AppLogger.info("Opening accessibility preferences")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Target identification

    /// Resolves the Accessibility elements that could be the requested window,
    /// best candidate first.
    func windowCandidates(for window: WindowInfo) -> [WindowFocusCandidate] {
        let ownerPID = window.ownerPID
        let appElement = AXUIElementCreateApplication(ownerPID)
        guard let axWindows = copyAXWindows(for: appElement, ownerPID: ownerPID), !axWindows.isEmpty else {
            AppLogger.warning("Candidate lookup found no AX windows. windowID=\(window.id), pid=\(ownerPID)")
            return []
        }

        // A synthesized ID (see WindowMonitorService.synthesizedWindowID) marks
        // a minimized window whose app does not expose a window number; it
        // cannot be correlated with the CG list, so only title matching works.
        let isSynthesized = window.id & 0x8000_0000 != 0

        var candidates: [WindowFocusCandidate] = []
        var accepted: [AXUIElement] = []

        func append(_ element: AXUIElement, reason: String, needsUnminimize: Bool = false) {
            guard !accepted.contains(where: { CFEqual($0, element) }) else { return }
            accepted.append(element)
            candidates.append(WindowFocusCandidate(element: element, reason: reason, needsUnminimize: needsUnminimize))
        }

        // 1. Exact window number, for the minority of apps that expose it.
        if !isSynthesized, let exact = axWindows.first(where: { axWindowNumber($0) == window.id }) {
            append(exact, reason: "axWindowNumber")
        }
        if window.isOnOtherSpace { return candidates }

        // 2. Scored matching (normalized title + geometry), best score first.
        let scored = axWindows
            .map { (element: $0, score: matchScore($0, target: window)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        // 3. Z-order correlation, but only when scoring cannot decide on its
        //    own. An exact title match plus matching geometry is stronger
        //    evidence than relative order, so it keeps precedence and apps that
        //    already switch correctly are unaffected; z-order is what resolves
        //    the case that scoring cannot — several windows that are identical
        //    in both title and geometry, or an app whose AX titles never match
        //    its CG titles (Chromium).
        let isDecisive = scored.count >= 1
            && scored[0].score >= Self.decisiveTitleScore
            && (scored.count == 1 || scored[1].score < scored[0].score)
        if !isDecisive, !isSynthesized, let correlated = zOrderMatchedAXWindow(for: window, in: axWindows) {
            append(correlated, reason: "zOrder")
        }

        for item in scored where item.score >= 30 {
            append(item.element, reason: "score:\(item.score)")
        }

        // 4. Minimized windows: the AX side knows the window is minimized and
        //    carries a title, which is the only handle a synthesized ID allows.
        for axWindow in axWindows where !accepted.contains(where: { CFEqual($0, axWindow) }) {
            guard !window.windowTitle.isEmpty,
                  axWindowIsMinimized(axWindow),
                  WindowTitleRules.matchStrength(
                      axTitle: axWindowTitle(axWindow) ?? "",
                      cgTitle: window.windowTitle
                  ) > 0 else { continue }
            append(axWindow, reason: "minimizedTitle", needsUnminimize: true)
        }

        // 5. Safety net, preserving the historical single-window fallback: with
        //    exactly one standard window there is nothing to disambiguate.
        if candidates.isEmpty {
            let standardLike = axWindows.filter { axWindowIsStandardLike($0) }
            if standardLike.count == 1, let only = standardLike.first {
                append(only, reason: "onlyStandardWindow")
            }
        }

        if candidates.isEmpty {
            AppLogger.warning("No candidate for window. windowID=\(window.id), axWindowCount=\(axWindows.count), standardLikeCount=\(axWindows.filter { axWindowIsStandardLike($0) }.count), title=\"\(window.windowTitle)\", bounds=\(window.bounds)")
        }
        return candidates
    }

    /// Estimates whether the Accessibility ordering is front-to-back, using the
    /// app's own focused window as a signal instead of assuming a direction: an
    /// app's focused window is almost always its frontmost one, so its position
    /// at either end of the list reveals the direction.
    ///
    /// The signal is read inside the geometry class first (precise, unaffected
    /// by the popup/utility windows some apps add) and falls back to the whole
    /// window list.
    private func axOrderIsFrontToBack(
        axClassMembers: [AXUIElement],
        allAXWindows: [AXUIElement],
        ownerPID: pid_t
    ) -> Bool {
        guard allAXWindows.count > 1 else { return true }

        let appElement = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return true
        }

        let focused = focusedValue as! AXUIElement

        if axClassMembers.count > 1,
           let classIndex = axClassMembers.firstIndex(where: { CFEqual($0, focused) }) {
            if classIndex == 0 { return true }
            if classIndex == axClassMembers.count - 1 { return false }
        }

        if let index = allAXWindows.firstIndex(where: { CFEqual($0, focused) }) {
            if index == 0 { return true }
            if index == allAXWindows.count - 1 { return false }
        }
        return true
    }

    /// Matches the target inside its geometry class using the relative order of
    /// the two window lists.
    ///
    /// Windows that are indistinguishable by geometry (same size *and* same
    /// origin — several maximized windows of one app) still have a unique
    /// front-to-back order, and CoreGraphics always enumerates front-to-back,
    /// so the relative position inside the class identifies the target without
    /// depending on any attribute an app may or may not report.
    private func zOrderMatchedAXWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        let cgWindows = onScreenWindows().filter { entry in
            entry.pid == window.ownerPID
                && entry.bounds.width >= Self.minimumWindowWidth
                && entry.bounds.height >= Self.minimumWindowHeight
        }
        guard !cgWindows.isEmpty else { return nil }

        let classMembers = cgWindows.filter { WindowGeometryRules.isSameClass($0.bounds, window.bounds) }
        guard classMembers.count > 1 else { return nil }
        guard let classIndex = classMembers.firstIndex(where: { $0.id == window.id }) else { return nil }

        let axClassMembers = axWindows.filter { element in
            guard let frame = axWindowFrame(element) else { return false }
            return WindowGeometryRules.isSameClass(frame, window.bounds)
        }
        guard axClassMembers.count == classMembers.count else { return nil }

        let frontToBack = axOrderIsFrontToBack(
            axClassMembers: axClassMembers,
            allAXWindows: axWindows,
            ownerPID: window.ownerPID
        )
        guard let axIndex = WindowZOrderPairing.index(
            inClass: classIndex,
            classCount: axClassMembers.count,
            axIsFrontToBack: frontToBack
        ) else {
            return nil
        }

        AppLogger.info("Matched AX window by z-order correlation. windowID=\(window.id), classCount=\(classMembers.count), classIndex=\(classIndex), axIndex=\(axIndex), axFrontToBack=\(frontToBack)")
        return axClassMembers[axIndex]
    }

    // MARK: - Raising and verifying

    /// Resolves the requested window and raises it, verifying with CoreGraphics
    /// at every step.
    ///
    /// Identification is treated as a *search* rather than a prediction. The
    /// heuristically ordered candidates are tried first — they are correct in
    /// the common case, and cheap — but if none of them verifiably becomes the
    /// frontmost window, the remaining Accessibility windows of the same app
    /// are probed one at a time, each with the same CoreGraphics check.
    ///
    /// This is what makes the multi-window case recoverable. Every identification
    /// heuristic (window number, title, geometry, relative order) can be wrong
    /// for some app, and when it is wrong the raise still "succeeds" — the app
    /// really does raise the window we pointed at, just not the one the user
    /// clicked. Predicting the mapping cannot fix that; checking the result can.
    /// A wrong guess now costs one bounded attempt instead of failing the switch.
    func resolveAndFocus(_ window: WindowInfo) -> Bool {
        // 跨桌面目标只提升精确身份，禁止失败后探测同应用的其他窗口。
        if window.isOnOtherSpace {
            guard let exact = windowCandidates(for: window).first?.element
                    ?? WindowSystemIdentity.remoteAXWindow(pid: window.ownerPID, windowID: window.id) else {
                AppLogger.error("Other-space target has no exact AX element. windowID=\(window.id)")
                return false
            }
            guard WindowSystemIdentity.requestFront(window) else {
                AppLogger.error("Other-space front request failed. windowID=\(window.id), pid=\(window.ownerPID)")
                return false
            }
            if focus(candidate: WindowFocusCandidate(element: exact, reason: "exactOtherSpace", needsUnminimize: window.isMinimized), window: window) { return true }
            if awaitLateFront(window) { return true }
            WindowSystemIdentity.forgetRemoteAXWindow(pid: window.ownerPID, windowID: window.id)
            return false
        }
        let candidates = windowCandidates(for: window)
        AppLogger.info("Resolved focus candidates. windowID=\(window.id), count=\(candidates.count), order=\(candidates.map { $0.reason }.joined(separator: ","))")

        var tried: [AXUIElement] = []
        func claim(_ element: AXUIElement) -> Bool {
            if tried.contains(where: { CFEqual($0, element) }) { return false }
            tried.append(element)
            return true
        }

        var attempts = 0
        for candidate in candidates where claim(candidate.element) {
            guard attempts < Self.maxFocusAttempts else { break }
            attempts += 1
            ensureApplicationFrontmost(pid: window.ownerPID)
            if focus(candidate: candidate, window: window) { return true }
            Thread.sleep(forTimeInterval: 0.04)
        }

        // Fallback: every window of the app we have not raised yet. Bounded, and
        // only reached when identification could not be trusted.
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        let remaining = (copyAXWindows(for: appElement, ownerPID: window.ownerPID) ?? [])
            .filter { element in !tried.contains(where: { CFEqual($0, element) }) }

        if !remaining.isEmpty, attempts < Self.maxFocusAttempts {
            AppLogger.info("Heuristic candidates did not match; probing remaining AX windows. windowID=\(window.id), remaining=\(remaining.count)")
        }

        for element in remaining {
            guard attempts < Self.maxFocusAttempts else { break }
            attempts += 1
            tried.append(element)
            ensureApplicationFrontmost(pid: window.ownerPID)
            let probe = WindowFocusCandidate(element: element, reason: "probe", needsUnminimize: false)
            if focus(candidate: probe, window: window) {
                AppLogger.info("Focused window by probing AX windows. windowID=\(window.id), attempt=\(attempts)")
                return true
            }
        }

        if awaitLateFront(window) { return true }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        AppLogger.error("Failed to focus window after all attempts. windowID=\(window.id), owner=\(window.ownerName), title=\"\(window.windowTitle)\", attempts=\(attempts), frontmostApp=\(frontmostApp?.localizedName ?? "nil")")
        return false
    }

    /// Re-checks a window whose verification already timed out. Succeeds only if
    /// the target itself reached the front, so a genuine failure is still reported.
    private func awaitLateFront(_ window: WindowInfo) -> Bool {
        for _ in 0..<Self.lateFrontGraceSampleCount {
            Thread.sleep(forTimeInterval: Self.frontmostSampleInterval)
            if isFrontmostOnScreen(window) {
                AppLogger.info("Focused window verified after grace wait. windowID=\(window.id)")
                return true
            }
        }
        return false
    }

    /// Re-activates the owning application while it is not frontmost.
    ///
    /// Raising a window of a background application is a no-op, so every
    /// attempt depends on the app being in front. Activation can be lost
    /// mid-switch: during measurement an unrelated application reclaimed the
    /// front between two attempts, after which the remaining attempts were all
    /// doomed. Re-asserting is cheap and makes the loop self-healing.
    private func ensureApplicationFrontmost(pid: pid_t, attempts: Int = 3) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        for _ in 0..<attempts {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
            app.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.06)
        }
    }

    /// Every Accessibility window the application exposes, in the app's own
    /// order. Unlike `windowCandidates` this applies no filtering at all, so the
    /// probe fallback can still reach a window that every heuristic rejects
    /// (missing subrole, unexpected size, no title).
    func allAXWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        return copyAXWindows(for: appElement, ownerPID: pid) ?? []
    }

    /// Brings one candidate to the front and verifies the result against the
    /// CoreGraphics window ordering.
    ///
    /// A single raise is not enough: activating an application and raising one
    /// of its windows is cooperative, and apps that manage their own key window
    /// (Chromium in particular) can re-assert their previous window shortly
    /// after. The raise is therefore sampled and re-applied.
    ///
    /// A candidate that never reaches the front is abandoned after one attempt:
    /// it is the wrong element, and continuing to raise it only delays the
    /// probe loop that can still find the right one.
    func focus(candidate: WindowFocusCandidate, window: WindowInfo) -> Bool {
        let element = candidate.element
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        AXUIElementSetMessagingTimeout(element, 1.0)

        if candidate.needsUnminimize {
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            Thread.sleep(forTimeInterval: 0.12)
        }

        for attempt in 1...Self.maxRaiseAttempts {
            raise(element, appElement: appElement)
            let outcome = sampleFrontmost(window: window)

            if outcome.sawTarget && outcome.stillTarget {
                AppLogger.info("Focused window verified by CoreGraphics. windowID=\(window.id), reason=\(candidate.reason), attempt=\(attempt)")
                return true
            }
            if outcome.sawTarget {
                AppLogger.warning("Target window reached the front but was replaced; re-raising. windowID=\(window.id), reason=\(candidate.reason), attempt=\(attempt)")
                continue
            }
            // Never reached the front — this is not the requested window.
            break
        }

        // Record what the raise actually produced. When identification is wrong
        // this line is the one that says so: it names the window that came
        // forward instead of the requested one.
        let observed = frontmostComparableWindow(to: window)
        AppLogger.warning("Candidate never became frontmost. windowID=\(window.id), reason=\(candidate.reason), observedFrontmost=\(observed.map { "\($0.id)" } ?? "nil")")
        return false
    }

    @discardableResult
    private func raise(_ window: AXUIElement, appElement: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        AppLogger.debug("Raise applied. raised=\(raised)")
        return raised
    }

    private func sampleFrontmost(window: WindowInfo) -> (sawTarget: Bool, stillTarget: Bool) {
        var sawTarget = false
        var stillTarget = false
        let sampleCount = window.isOnOtherSpace ? Self.otherSpaceSampleCount : Self.frontmostSampleCount
        var consecutiveMatches = 0
        for index in 0..<sampleCount {
            Thread.sleep(forTimeInterval: Self.frontmostSampleInterval)
            let frontmost = isFrontmostOnScreen(window)
            sawTarget = sawTarget || frontmost
            consecutiveMatches = frontmost ? consecutiveMatches + 1 : 0
            if index == sampleCount - 1 || consecutiveMatches >= Self.frontmostSampleCount {
                stillTarget = frontmost
                break
            }
        }
        return (sawTarget, stillTarget)
    }

    /// Ground truth for "the user can see this window in front": the target must
    /// be the frontmost eligible window in the CoreGraphics list.
    ///
    /// `CGWindowListCopyWindowInfo` enumerates front-to-back, so the first
    /// eligible entry *is* the frontmost window on screen; if it belongs to
    /// another window (of the same app or of a different app) the target is not
    /// in front. Windows smaller than the monitor's threshold are skipped so
    /// invisible 1×1 helper surfaces cannot masquerade as the front window.
    func isFrontmostOnScreen(_ window: WindowInfo) -> Bool {
        guard let frontmost = frontmostComparableWindow(to: window) else { return false }

        if frontmost.pid == window.ownerPID && frontmost.id == window.id {
            if window.isOnOtherSpace {
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(window.ownerPID),
                    kAXFocusedWindowAttribute as CFString, &focused) == .success,
                    let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
                return WindowSystemIdentity.windowID(focused as! AXUIElement) == window.id
            }
            return true
        }

        // A minimized window carries a synthesized ID, so its identity is
        // confirmed by title instead.
        if window.id & 0x8000_0000 != 0 {
            return frontmost.pid == window.ownerPID
                && WindowTitleRules.matchStrength(axTitle: frontmost.title, cgTitle: window.windowTitle) > 0
        }
        return false
    }

    /// The frontmost on-screen window whose size is comparable to the target's.
    ///
    /// Verification has to ignore transient overlay surfaces. Chrome's tab-hover
    /// bubble ("You can now expand your tabs…") is a layer-0 window measuring
    /// 362×168, so it passes the absolute 80×60 floor used for the window list
    /// and can sit on top of the window we just raised — making a successful
    /// raise look like a failure and sending the caller off to try other
    /// candidates. A threshold relative to the target keeps overlays out of the
    /// comparison while still detecting a *real* window of another app sitting
    /// in front (which is much closer to the target in size).
    private func frontmostComparableWindow(to window: WindowInfo) -> CGWindowEntry? {
        let minWidth = max(Self.minimumWindowWidth, window.bounds.width * 0.5)
        let minHeight = max(Self.minimumWindowHeight, window.bounds.height * 0.5)
        return onScreenWindows().first { entry in
            entry.bounds.width >= minWidth && entry.bounds.height >= minHeight
        }
    }

    func bringWindowToFront(_ window: WindowInfo) -> Bool {
        AppLogger.info("Bringing window to front. windowID=\(window.id)")
        return resolveAndFocus(window)
    }

    func bringWindowToFront(_ windowID: CGWindowID) -> Bool {
        AppLogger.info("Attempting to bring window to front. windowID=\(windowID)")

        // Look up the owner PID for this window from the system window list.
        guard let windowInfo = windowInfo(for: windowID) else {
            AppLogger.error("Failed to find window info for windowID=\(windowID)")
            return false
        }

        return bringWindowToFront(windowInfo)
    }

    func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )

        if result == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID(),
           let windowID = axWindowNumber(focusedValue as! AXUIElement) {
            return windowID
        }

        let fallbackWindowID = frontmostCGWindowID(for: pid)
        AppLogger.warning("Unable to read focused AX window; falling back to CG frontmost window. pid=\(pid), result=\(result.rawValue), fallbackWindowID=\(fallbackWindowID.map { "\($0)" } ?? "nil")")
        return fallbackWindowID
    }

    // MARK: - Window list access

    /// Ordered front-to-back, exactly as the window server reports it.
    private struct CGWindowEntry {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let bounds: CGRect
    }

    private func onScreenWindows() -> [CGWindowEntry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var entries: [CGWindowEntry] = []
        for dict in windowList {
            guard let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let id = dict[kCGWindowNumber as String] as? CGWindowID,
                  let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  dict[kCGWindowBounds as String] is [String: Any] else {
                continue
            }
            entries.append(
                CGWindowEntry(
                    id: id,
                    pid: pid,
                    title: dict[kCGWindowName as String] as? String ?? "",
                    // Note: `extractCGRect` reads kCGWindowBounds itself, so it
                    // takes the window dictionary, not the bounds dictionary.
                    bounds: extractCGRect(from: dict)
                )
            )
        }
        return entries
    }

    private func frontmostCGWindowID(for ownerPID: pid_t) -> CGWindowID? {
        for entry in onScreenWindows() where entry.pid == ownerPID {
            if entry.bounds.width >= Self.minimumWindowWidth, entry.bounds.height >= Self.minimumWindowHeight {
                return entry.id
            }
        }
        return nil
    }

    /// Retrieves WindowInfo (including owner PID) for a given CGWindowID.
    private func windowInfo(for windowID: CGWindowID) -> WindowInfo? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for dict in windowList {
            guard let wid = dict[kCGWindowNumber as String] as? CGWindowID,
                  wid == windowID,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = dict[kCGWindowOwnerName as String] as? String else {
                continue
            }

            let windowTitle = dict[kCGWindowName as String] as? String ?? ""
            let bounds = extractCGRect(from: dict)

            return WindowInfo(
                id: wid,
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowTitle: windowTitle,
                bounds: bounds,
                isOnCurrentSpace: true,
                windowNumber: Int(wid)
            )
        }

        return nil
    }

    private func extractCGRect(from dict: [String: Any]) -> CGRect {
        guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else {
            return .zero
        }
        let x = cgFloatValue(boundsDict["X"])
        let y = cgFloatValue(boundsDict["Y"])
        let width = cgFloatValue(boundsDict["Width"])
        let height = cgFloatValue(boundsDict["Height"])
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func cgFloatValue(_ value: Any?) -> CGFloat {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? NSNumber {
            return CGFloat(value.doubleValue)
        }
        return 0
    }

    // MARK: - Accessibility queries

    private func copyAXWindows(for appElement: AXUIElement, ownerPID: pid_t) -> [AXUIElement]? {
        let timeouts: [Float] = [0.6, 1.5, 3.0]

        for (attempt, timeout) in timeouts.enumerated() {
            AXUIElementSetMessagingTimeout(appElement, timeout)
            var windowsValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            )

            if result == .success,
               let windows = windowsValue as? [AXUIElement] {
                if attempt > 0 {
                    AppLogger.info("Copied AX windows after retry. pid=\(ownerPID), attempt=\(attempt + 1), timeout=\(timeout), count=\(windows.count)")
                }
                return windows
            }

            AppLogger.warning("Failed to copy AX windows. pid=\(ownerPID), attempt=\(attempt + 1), timeout=\(timeout), result=\(result.rawValue), hasValue=\(windowsValue != nil)")
            Thread.sleep(forTimeInterval: 0.08)
        }

        AppLogger.error("Failed to copy AX windows after retries. pid=\(ownerPID)")
        return nil
    }

    /// Score of an Accessibility window against the requested window, using the
    /// shared rules so that the two title spellings an app may use still match.
    private func matchScore(_ axWindow: AXUIElement, target: WindowInfo) -> Int {
        var score = WindowTitleRules.score(
            axTitle: axWindowTitle(axWindow) ?? "",
            cgTitle: target.windowTitle
        )

        if let frame = axWindowFrame(axWindow) {
            if WindowGeometryRules.isSameSize(frame, target.bounds) {
                score += 25
            }
            if WindowGeometryRules.isSamePosition(frame, target.bounds) {
                score += 20
            }
        }

        return score
    }

    private func axWindowNumber(_ window: AXUIElement) -> CGWindowID? {
        WindowSystemIdentity.windowID(window)
    }

    private func axWindowSubrole(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    /// Whether the element is a normal window.
    ///
    /// A missing subrole means "unknown", not "not a window": filtering those
    /// out emptied the candidate pool entirely for some apps (measured:
    /// `axWindowCount=3, standardWindowCount=0`, a hard switch failure), so an
    /// unavailable attribute is treated as standard — the same assumption
    /// `WindowMonitorService.axWindowIsStandard` already makes.
    private func axWindowIsStandardLike(_ window: AXUIElement) -> Bool {
        guard let subrole = axWindowSubrole(window) else { return true }
        return subrole == kAXStandardWindowSubrole
    }

    private func axWindowIsMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        if let isMinimized = value as? Bool {
            return isMinimized
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func axWindowTitle(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func axWindowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)

        guard positionResult == .success,
              sizeResult == .success,
              let positionAXValue = positionValue,
              let sizeAXValue = sizeValue,
              CFGetTypeID(positionAXValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeAXValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    // MARK: - Window control helpers

    func setWindowPosition(_ windowID: CGWindowID, frame: CGRect) -> Bool {
        AppLogger.warning("setWindowPosition is not implemented. windowID=\(windowID), frame=\(frame)")
        return true
    }

    func listAllWindows() -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            AppLogger.error("CGWindowListCopyWindowInfo returned nil while listing all window IDs")
            return []
        }

        let windowIDs = windowList.compactMap { dict in
            dict[kCGWindowNumber as String] as? CGWindowID
        }
        AppLogger.debug("Listed all window IDs. count=\(windowIDs.count)")
        return windowIDs
    }

    /// Finds the AXUIElement window that matches the given WindowInfo, using the
    /// same ordered candidate strategy as the switch pipeline. Returns nil if no
    /// matching AX window can be found.
    func findAXWindow(for window: WindowInfo) -> AXUIElement? {
        guard let targetWindow = windowCandidates(for: window).first?.element else {
            AppLogger.warning("findAXWindow: no matching AX window found. windowID=\(window.id)")
            return nil
        }

        // Set a short messaging timeout on the returned window element so that
        // subsequent AX calls (e.g. reading children, finding buttons) do not
        // hang for the default timeout (potentially 5-6 seconds).
        AXUIElementSetMessagingTimeout(targetWindow, 0.5)
        return targetWindow
    }
}
