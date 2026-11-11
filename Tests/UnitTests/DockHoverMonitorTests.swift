//
//  DockHoverMonitorTests.swift
//  SwitchlyTests
//
//  Headless tests for the dock-hover decisions that keep the preview from
//  being stranded on screen or block the pointer loop with synchronous AX
//  work. The monitor itself is wired to NSEvent, timers and DockPreviewPanel.
//

import XCTest
@testable import Switchly

final class DockHoverMonitorTests: XCTestCase {
    func testNativePointResultIsNotReusedForAnotherPointerLocation() {
        let calls = LockedCallCounter()
        let monitor = DockHoverMonitor(queryDockIconAtPoint: { point in
            calls.increment()
            return DockIconInfo(appName: point.x < 50 ? "A" : "B",
                                frame: CGRect(x: 0, y: 0, width: 100, height: 100), bundleURL: nil)
        }, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        XCTAssertNil(monitor.dockIconAtLocation(NSPoint(x: 20, y: 20)))
        waitForDockIconScanToFinish(monitor)
        XCTAssertEqual(monitor.dockIconAtLocation(NSPoint(x: 20, y: 20))?.appName, "A")
        XCTAssertNil(monitor.dockIconAtLocation(NSPoint(x: 80, y: 20)), "放大布局旧命中不能冒充新位置")
        waitForDockIconScanToFinish(monitor)
        XCTAssertEqual(monitor.dockIconAtLocation(NSPoint(x: 80, y: 20))?.appName, "B")
        XCTAssertEqual(calls.value, 2)
    }

    func testHiddenDockPointDoesNotBecomeAnIconFromCachedGeometry() {
        let calls = LockedCallCounter()
        let monitor = DockHoverMonitor(queryDockIconAtPoint: { _ in calls.increment(); return nil },
                                      now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        XCTAssertNil(monitor.dockIconAtLocation(NSPoint(x: 20, y: 20)))
        waitForDockIconScanToFinish(monitor)
        XCTAssertNil(monitor.dockIconAtLocation(NSPoint(x: 20, y: 20)))
        XCTAssertEqual(calls.value, 1)
    }

    func testAnchorComparisonTracksMagnificationButIgnoresAXVerticalOrigin() {
        let original = CGRect(x: 100, y: 900, width: 54, height: 70)
        XCTAssertTrue(DockPanelMetrics.sameAnchor(original, original.offsetBy(dx: 0, dy: -200)))
        XCTAssertFalse(DockPanelMetrics.sameAnchor(original, CGRect(x: 80, y: 870, width: 94, height: 103)))
    }
    func testQueuedPointerBurstProcessesOnlyTheLatestTarget() {
        let samples = DockPointerSamples()
        let drained = expectation(description: "latest pointer target processed")
        var processed: [NSPoint] = []
        for x in 0..<100 {
            if samples.offer(NSPoint(x: x, y: 20)) {
                DispatchQueue.main.async {
                    if let point = samples.take() { processed.append(point) }
                    drained.fulfill()
                }
            }
        }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(processed, [NSPoint(x: 99, y: 20)])
    }

    func testStoppedPointerBurstDoesNotRestoreAnOldTarget() {
        let samples = DockPointerSamples()
        XCTAssertTrue(samples.offer(NSPoint(x: 20, y: 20)))
        samples.clear()
        XCTAssertNil(samples.take())
        XCTAssertTrue(samples.offer(NSPoint(x: 80, y: 20)))
        XCTAssertEqual(samples.take(), NSPoint(x: 80, y: 20))
    }

    // MARK: Desync recovery

    /// Regression: `DockPreviewPanel.show` refreshes the window list — running
    /// Accessibility work that can pump the run loop — before it orders the
    /// panel on screen. A poll tick landing in that window sees
    /// `isShowing == true` with the panel not visible yet; that is a
    /// presentation in flight, not a desync.
    ///
    /// Reading it as a desync used to clear `isShowing`/`currentIcon` *after*
    /// `showPreview()` had claimed them, so the panel appeared with the
    /// monitor no longer tracking it and never auto-hid.
    func testInFlightPresentationIsNotTreatedAsDesync() {
        XCTAssertFalse(DockHoverState.isDesynced(isShowing: true,
                                                 isPresentationPending: true,
                                                 panelVisible: false))
    }

    /// The panel really did disappear (Escape, a card click): recover so the
    /// next hover can re-trigger the preview.
    func testVanishedPanelIsTreatedAsDesync() {
        XCTAssertTrue(DockHoverState.isDesynced(isShowing: true,
                                                isPresentationPending: false,
                                                panelVisible: false))
    }

    /// Nothing to recover while the panel is on screen.
    func testVisiblePanelIsNotADesync() {
        XCTAssertFalse(DockHoverState.isDesynced(isShowing: true,
                                                 isPresentationPending: false,
                                                 panelVisible: true))
    }

    /// A monitor that is not showing anything has nothing to desync.
    func testIdleMonitorIsNotADesync() {
        XCTAssertFalse(DockHoverState.isDesynced(isShowing: false,
                                                 isPresentationPending: false,
                                                 panelVisible: false))
    }

    // MARK: Dismissal

    /// The reported bug: the panel is on screen but the monitor's `isShowing`
    /// flag was reset, so the old `isShowing`-gated hide never fired and the
    /// preview stayed up until something else dismissed it. Dismissal follows
    /// the panel's real visibility instead.
    func testVisiblePanelIsDismissedWithStaleMonitorFlag() {
        XCTAssertTrue(DockHoverState.shouldDismiss(panelVisible: true,
                                                   pointerInDockArea: false,
                                                   pointerInPanel: false))
    }

    /// The pointer travelled from the Dock up into the panel: keep it up so
    /// the user can click a window card.
    func testVisiblePanelStaysWhilePointerIsInPanel() {
        XCTAssertFalse(DockHoverState.shouldDismiss(panelVisible: true,
                                                    pointerInDockArea: false,
                                                    pointerInPanel: true))
    }

    /// The pointer is still over the Dock: keep the preview up.
    func testVisiblePanelStaysWhilePointerIsInDockArea() {
        XCTAssertFalse(DockHoverState.shouldDismiss(panelVisible: true,
                                                    pointerInDockArea: true,
                                                    pointerInPanel: false))
    }

    /// A panel that is already gone must not schedule a dismissal.
    func testInvisiblePanelIsNotDismissed() {
        XCTAssertFalse(DockHoverState.shouldDismiss(panelVisible: false,
                                                    pointerInDockArea: false,
                                                    pointerInPanel: false))
    }

    // MARK: Hover-delay scheduling

    /// Regression: moving within one Dock icon kept invalidating and recreating
    /// the show-delay timer, pushing the preview deadline out indefinitely.
    func testSameIconKeepsPendingShowDelay() {
        let url = URL(fileURLWithPath: "/Applications/Same.app")
        let current = DockIconInfo(appName: "Same",
                                   frame: CGRect(x: 0, y: 0, width: 40, height: 40),
                                   bundleURL: url)
        let hovered = DockIconInfo(appName: "Same",
                                   frame: CGRect(x: 0, y: 0, width: 80, height: 80),
                                   bundleURL: url)

        XCTAssertEqual(DockHoverState.iconTransition(currentIcon: current,
                                                     hoveredIcon: hovered,
                                                     isShowing: false),
                       .retain)
    }

    /// The delay belongs to the hovered product, so crossing to another icon
    /// must replace it before it can show the previous target.
    func testDifferentIconRestartsPendingShowDelay() {
        let current = DockIconInfo(appName: "Previous",
                                   frame: CGRect(x: 0, y: 0, width: 40, height: 40),
                                   bundleURL: nil)
        let hovered = DockIconInfo(appName: "Next",
                                   frame: CGRect(x: 40, y: 0, width: 40, height: 40),
                                   bundleURL: nil)

        XCTAssertEqual(DockHoverState.iconTransition(currentIcon: current,
                                                     hoveredIcon: hovered,
                                                     isShowing: false),
                       .startDelay)
    }

    /// Once visible, crossing icons still switches immediately without
    /// introducing the hover delay again.
    func testDifferentIconSwitchesImmediatelyWhileShowing() {
        let current = DockIconInfo(appName: "Previous",
                                   frame: CGRect(x: 0, y: 0, width: 40, height: 40),
                                   bundleURL: nil)
        let hovered = DockIconInfo(appName: "Next",
                                   frame: CGRect(x: 40, y: 0, width: 40, height: 40),
                                   bundleURL: nil)

        XCTAssertEqual(DockHoverState.iconTransition(currentIcon: current,
                                                     hoveredIcon: hovered,
                                                     isShowing: true),
                       .switchImmediately)
    }

    // MARK: Background AX scheduling

    /// A slow AX walk must not block the pointer loop, and repeated samples
    /// while it runs must not enqueue another scan.
    func testMissingCacheSchedulesOneNonBlockingBackgroundScan() {
        let scanStarted = expectation(description: "background scan started")
        let scanGate = DispatchSemaphore(value: 0)
        let calls = LockedCallCounter()
        let monitor = DockHoverMonitor(queryDockIcons: {
            calls.increment()
            scanStarted.fulfill()
            scanGate.wait()
            return []
        })
        defer {
            scanGate.signal()
            monitor.stop()
        }

        let point = NSPoint(x: 20, y: 20)
        XCTAssertNil(monitor.dockIconAtLocation(point))
        XCTAssertNil(monitor.dockIconAtLocation(point))

        wait(for: [scanStarted], timeout: 2)
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(monitor.isDockIconScanInFlight)

        scanGate.signal()
        waitForDockIconScanToFinish(monitor)
    }

    /// The first sample can return nil before the background walk finishes;
    /// the published cache then answers the next pointer sample immediately.
    func testCompletedBackgroundScanPublishesCacheForNextSample() {
        let scanStarted = expectation(description: "background scan started")
        let scanGate = DispatchSemaphore(value: 0)
        let calls = LockedCallCounter()
        let result = DockIconInfo(appName: "Result",
                                  frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  bundleURL: nil)
        let monitor = DockHoverMonitor(queryDockIcons: {
            calls.increment()
            scanStarted.fulfill()
            scanGate.wait()
            return [result]
        }, now: { Date(timeIntervalSince1970: 100) })
        defer {
            scanGate.signal()
            monitor.stop()
        }

        let point = NSPoint(x: 20, y: 20)
        XCTAssertNil(monitor.dockIconAtLocation(point))
        wait(for: [scanStarted], timeout: 2)
        scanGate.signal()
        waitForDockIconScanToFinish(monitor)

        XCTAssertEqual(monitor.cachedDockIcons?.first?.appName, "Result")
        XCTAssertEqual(monitor.dockIconAtLocation(point)?.appName, "Result")
        XCTAssertEqual(calls.value, 1)
    }

    /// Stopping invalidates the scan generation. The queue task must finish so
    /// the in-flight latch clears, but its stale result cannot repopulate cache.
    func testStopRejectsLateBackgroundScanResult() {
        let scanStarted = expectation(description: "background scan started")
        let scanGate = DispatchSemaphore(value: 0)
        let calls = LockedCallCounter()
        let result = DockIconInfo(appName: "Stale",
                                  frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  bundleURL: nil)
        let monitor = DockHoverMonitor(queryDockIcons: {
            calls.increment()
            scanStarted.fulfill()
            scanGate.wait()
            return [result]
        })
        defer {
            scanGate.signal()
            monitor.stop()
        }

        XCTAssertNil(monitor.dockIconAtLocation(NSPoint(x: 20, y: 20)))
        wait(for: [scanStarted], timeout: 2)
        monitor.stop()
        XCTAssertTrue(monitor.isDockIconScanInFlight)

        scanGate.signal()
        waitForDockIconScanToFinish(monitor)
        XCTAssertNil(monitor.cachedDockIcons)
        XCTAssertEqual(calls.value, 1)
    }

    // MARK: Icon matching

    private func icon(_ name: String, x: CGFloat, y: CGFloat, size: CGFloat = 40) -> DockIconInfo {
        DockIconInfo(appName: name, frame: CGRect(x: x, y: y, width: size, height: size), bundleURL: nil)
    }

    /// A bottom Dock lays icons out horizontally: the x span decides.
    func testBottomDockMatchesAlongX() {
        let icons = [
            icon("A", x: 0, y: 0),
            icon("B", x: 40, y: 0),
            icon("C", x: 80, y: 0),
        ]
        XCTAssertEqual(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 50, y: 20), orientation: "bottom")?.appName, "B")
        XCTAssertEqual(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 5, y: 20), orientation: "bottom")?.appName, "A")
    }

    /// Regression: a left/right Dock stacks icons vertically, so they all
    /// share the x span. The old x-only matching hit every icon in the column
    /// and the near-identical x distances made the pick arbitrary — hovering
    /// one icon previewed another.
    func testSideDockMatchesAlongYNotX() {
        let icons = [
            icon("A", x: 0, y: 0),
            icon("B", x: 0, y: 40),
            icon("C", x: 0, y: 80),
        ]
        // Same x for all three; only the y coordinate discriminates.
        XCTAssertEqual(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 20, y: 10), orientation: "left")?.appName, "A")
        XCTAssertEqual(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 20, y: 50), orientation: "left")?.appName, "B")
        XCTAssertEqual(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 20, y: 90), orientation: "right")?.appName, "C")
    }

    /// A point outside every icon's layout-axis span matches nothing.
    func testPointOutsideEveryIconReturnsNil() {
        let icons = [
            icon("A", x: 0, y: 0),
            icon("B", x: 40, y: 0),
        ]
        XCTAssertNil(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 200, y: 20), orientation: "bottom"))
        XCTAssertNil(DockHoverState.bestIcon(in: icons, at: NSPoint(x: 20, y: 200), orientation: "left"))
    }

    // MARK: Auto-hide extent

    /// Regression: with magnification a hovered icon is ~150 pt tall, taller
    /// than the fixed 80 pt strip, so the pointer on it fell outside the Dock
    /// area and the preview went dead until the pointer re-touched the edge.
    func testAutohideExtentGrowsWithMagnifiedIcons() {
        let icons = [icon("A", x: 0, y: 0, size: 98), icon("B", x: 98, y: 0, size: 149)]
        XCTAssertEqual(DockHoverState.autohideExtent(icons: icons, orientation: "bottom"), 165)
    }

    func testAutohideExtentNeverShrinksBelowTheMinimumStrip() {
        XCTAssertEqual(DockHoverState.autohideExtent(icons: [icon("A", x: 0, y: 0)], orientation: "bottom"), 80)
        XCTAssertEqual(DockHoverState.autohideExtent(icons: [], orientation: "bottom"), 80)
    }

    func testAutohideExtentUsesWidthForSideDock() {
        let tall = DockIconInfo(appName: "A", frame: CGRect(x: 0, y: 0, width: 120, height: 30), bundleURL: nil)
        XCTAssertEqual(DockHoverState.autohideExtent(icons: [tall], orientation: "left"), 136)
    }

    private func waitForDockIconScanToFinish(_ monitor: DockHoverMonitor) {
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let monitor = object as? DockHoverMonitor else { return false }
                return !monitor.isDockIconScanInFlight
            },
            object: monitor
        )
        wait(for: [finished], timeout: 2)
    }
}

private final class LockedCallCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
