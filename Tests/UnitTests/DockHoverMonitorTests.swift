//
//  DockHoverMonitorTests.swift
//  SwitchlyTests
//
//  Headless tests for the dock-hover decisions that keep the preview from
//  being stranded on screen. The monitor itself is wired to NSEvent, timers
//  and DockPreviewPanel, so it is covered here through its two pure decisions
//  rather than by faking the window server.
//

import XCTest
@testable import Switchly

final class DockHoverMonitorTests: XCTestCase {

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
}
