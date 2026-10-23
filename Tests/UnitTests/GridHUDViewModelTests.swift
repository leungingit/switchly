//
//  GridHUDViewModelTests.swift
//  SwitchlyTests
//
//  The HUD state machine driven by synthetic swipes and fabricated snapshots:
//  switching, edge, cooldown, not created, unavailable, accessibility failure.
//

import XCTest
import CoreGraphics
@testable import Switchly

@MainActor
final class GridHUDViewModelTests: XCTestCase {

    private func snapshot(count: Int, current: Int) -> DesktopSpaceSnapshot {
        let desktops = (1...max(1, count)).map { number in
            Desktop(
                id: UInt64(number),
                number: number,
                isCurrent: number == current,
                windows: number == 2 ? [] : [window(number)]
            )
        }
        return DesktopSpaceSnapshot(
            desktops: desktops,
            availability: .available,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func swipe(_ direction: SwipeDirection, suppressed: Bool = false) -> TrackpadSwipeEvent {
        TrackpadSwipeEvent(
            gesture: SwipeGesture(
                direction: direction,
                angleDegrees: direction.angleDegrees,
                displacementMM: 18,
                fingers: 4,
                duration: 0.12
            ),
            suppressed: suppressed
        )
    }

    private func makeViewModel(
        accessibility: Bool = true,
        language: AppLanguage = .english
    ) -> GridHUDViewModel {
        GridHUDViewModel(
            language: language,
            accessibilityStatus: { accessibility }
        )
    }

    // MARK: - Switching

    func testSwipeInsideTheGridRequestsNavigationAndShowsSwitching() {
        let viewModel = makeViewModel()
        let action = viewModel.handle(
            swipe: swipe(.downRight),
            snapshot: snapshot(count: 9, current: 5)
        )

        XCTAssertEqual(action, .navigate(9))
        XCTAssertEqual(viewModel.phase, .switching)
        XCTAssertEqual(viewModel.targetNumber, 9)
        XCTAssertEqual(viewModel.currentNumber, 5)
        XCTAssertTrue(viewModel.isVisible)
        XCTAssertEqual(viewModel.headline, "Desktop 5 → 9")
        XCTAssertEqual(viewModel.arrowSymbol, "arrow.down.right")
        XCTAssertTrue(viewModel.isHighlighted(.downRight))
        XCTAssertFalse(viewModel.isHighlighted(.upLeft))
        XCTAssertNil(viewModel.autoDismissDelay, "the switching state hides on completion")
    }

    func testGestureHintMentionsDirectionAndKey() {
        let viewModel = makeViewModel()
        _ = viewModel.handle(swipe: swipe(.up), snapshot: snapshot(count: 9, current: 5))

        let hint = viewModel.gestureHint ?? ""
        XCTAssertTrue(hint.contains("Up"))
        XCTAssertTrue(hint.contains("⌃2"))
    }

    func testChineseCopyFollowsTheInjectedLanguage() {
        let viewModel = makeViewModel(language: .simplifiedChinese)
        _ = viewModel.handle(swipe: swipe(.right), snapshot: snapshot(count: 9, current: 5))

        XCTAssertEqual(viewModel.headline, "桌面 5 → 6")
        XCTAssertTrue((viewModel.gestureHint ?? "").contains("四指向右滑动"))
    }

    func testFinishingASwitchHidesTheHUD() {
        let viewModel = makeViewModel()
        _ = viewModel.handle(swipe: swipe(.right), snapshot: snapshot(count: 9, current: 5))
        viewModel.finish(navigation: .switched(number: 6, path: .applicationActivation, confirmed: true))

        XCTAssertFalse(viewModel.isVisible)
        XCTAssertNil(viewModel.phase)
        XCTAssertNil(viewModel.targetNumber)
    }

    // MARK: - Edge

    func testEdgeSwipesDoNotNavigateAndNeverWrap() {
        let viewModel = makeViewModel()
        // Desktop 1 is the top-left cell: up, left and up-left all leave it.
        for direction in [SwipeDirection.up, .left, .upLeft] {
            let action = viewModel.handle(swipe: swipe(direction), snapshot: snapshot(count: 9, current: 1))
            XCTAssertEqual(action, .none)
            XCTAssertEqual(viewModel.phase, .edge)
            XCTAssertNil(viewModel.targetNumber)
            XCTAssertTrue(viewModel.phase?.isWarning == true)
        }

        // Desktop 9 is the bottom-right cell.
        for direction in [SwipeDirection.down, .right, .downRight] {
            let action = viewModel.handle(swipe: swipe(direction), snapshot: snapshot(count: 9, current: 9))
            XCTAssertEqual(action, .none)
            XCTAssertEqual(viewModel.phase, .edge)
        }
    }

    func testEdgeStateAutoDismissesAfterItsDwell() {
        let viewModel = makeViewModel()
        _ = viewModel.handle(swipe: swipe(.up), snapshot: snapshot(count: 9, current: 1))
        XCTAssertEqual(viewModel.autoDismissDelay, GridHUDViewModel.warningDwell)
    }

    // MARK: - Cooldown

    func testSuppressedSwipeShowsCooldownAndDoesNotNavigate() {
        let viewModel = makeViewModel()
        let action = viewModel.handle(
            swipe: swipe(.down, suppressed: true),
            snapshot: snapshot(count: 9, current: 5)
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(viewModel.phase, .coolingDown)
        XCTAssertNil(viewModel.targetNumber)
        XCTAssertEqual(viewModel.title, "Cooling down")
    }

    // MARK: - Not created

    func testNotCreatedTargetIsReportedAndNotSwitched() {
        let viewModel = makeViewModel()
        // Only five desktops exist; desktop 6 does not.
        let action = viewModel.handle(swipe: swipe(.right), snapshot: snapshot(count: 5, current: 5))

        XCTAssertEqual(action, .none)
        XCTAssertEqual(viewModel.phase, .notCreated)
        XCTAssertEqual(viewModel.targetNumber, 6)
        XCTAssertEqual(viewModel.title, "Desktop 6 not created")
        XCTAssertEqual(viewModel.arrowSymbol, "", "a warning state must not show a swipe arrow")
        XCTAssertFalse(viewModel.isHighlighted(.right))
        XCTAssertEqual(viewModel.miniState(for: 6), .missing)
        XCTAssertEqual(viewModel.miniState(for: 5), .current)
    }

    func testMiniMapMarksCurrentAndTarget() {
        let viewModel = makeViewModel()
        _ = viewModel.handle(swipe: swipe(.downRight), snapshot: snapshot(count: 9, current: 5))

        XCTAssertEqual(viewModel.miniState(for: 5), .current)
        XCTAssertEqual(viewModel.miniState(for: 9), .target)
        XCTAssertEqual(viewModel.miniState(for: 1), .plain)
    }

    // MARK: - Failure and unavailable

    func testFailedSwitchWithAccessibilityMissingShowsPermissionState() {
        let viewModel = makeViewModel(accessibility: false)
        _ = viewModel.handle(swipe: swipe(.right), snapshot: snapshot(count: 9, current: 5))
        viewModel.finish(navigation: .failed(reason: "activation_failed"))

        XCTAssertEqual(viewModel.phase, .accessibilityMissing)
        XCTAssertTrue(viewModel.isVisible)
        XCTAssertEqual(viewModel.title, "Accessibility permission required")
    }

    func testFailedSwitchWithPermissionsShowsUnavailable() {
        let viewModel = makeViewModel()
        _ = viewModel.handle(swipe: swipe(.right), snapshot: snapshot(count: 9, current: 5))
        viewModel.finish(navigation: .failed(reason: "hotkey_not_configured"))

        XCTAssertEqual(viewModel.phase, .failed)
        XCTAssertTrue(viewModel.isVisible)
        XCTAssertEqual(viewModel.title, "Could not switch desktop")
    }

    func testUnavailableSnapshotIsReportedAsUnavailable() {
        let viewModel = makeViewModel()
        let action = viewModel.handle(
            swipe: swipe(.right),
            snapshot: .unavailable(reason: "test")
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(viewModel.phase, .spacesUnavailable)
        XCTAssertTrue(viewModel.isVisible)
        XCTAssertEqual(viewModel.title, "Desktop information is unavailable")
    }

    // MARK: - Helpers

    private func window(_ id: Int) -> WindowInfo {
        WindowInfo(
            id: CGWindowID(id),
            ownerPID: pid_t(id),
            ownerName: "App \(id)",
            windowTitle: "Window \(id)",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: false,
            windowNumber: id
        )
    }

    // MARK: - Pure mapping

    func testTargetMappingCoversEveryCellAndStaysInsideTheGrid() {
        XCTAssertEqual(GridHUDViewModel.target(from: 5, direction: .upLeft), 1)
        XCTAssertEqual(GridHUDViewModel.target(from: 5, direction: .downRight), 9)
        XCTAssertEqual(GridHUDViewModel.target(from: 1, direction: .right), 2)
        XCTAssertEqual(GridHUDViewModel.target(from: 1, direction: .down), 4)
        XCTAssertNil(GridHUDViewModel.target(from: 3, direction: .right))
        XCTAssertNil(GridHUDViewModel.target(from: 7, direction: .left))
        XCTAssertNil(GridHUDViewModel.target(from: 0, direction: .right))
    }
}
