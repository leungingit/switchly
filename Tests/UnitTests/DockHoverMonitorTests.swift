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
}
