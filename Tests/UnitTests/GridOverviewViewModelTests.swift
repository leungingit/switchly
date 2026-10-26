//
//  GridOverviewViewModelTests.swift
//  SwitchlyTests
//
//  Selection, nine-slot mapping and permission degradation for the desktop
//  grid overview. The Space service is faked; no system call is made.
//

import XCTest
import CoreGraphics
@testable import Switchly

private final class StubDesktopSpaceService: DesktopSpaceServiceProtocol {
    var snapshot: DesktopSpaceSnapshot

    init(snapshot: DesktopSpaceSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async -> DesktopSpaceSnapshot { snapshot }
}

@MainActor
final class GridOverviewViewModelTests: XCTestCase {

    private func makeSnapshot(
        count: Int,
        current: Int = 1,
        unavailable: Bool = false
    ) -> DesktopSpaceSnapshot {
        if unavailable {
            return .unavailable(reason: "test")
        }
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

    private func makeViewModel(
        snapshot: DesktopSpaceSnapshot,
        accessibility: Bool = true,
        screenRecording: Bool = true
    ) -> GridOverviewViewModel {
        GridOverviewViewModel(
            spaceService: StubDesktopSpaceService(snapshot: snapshot),
            accessibilityStatus: { accessibility },
            screenRecordingStatus: { screenRecording }
        )
    }

    func testSwapPositionsRemapsSlotsAndReportsLayout() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        var reported: [Int]?
        var reportedKey: String?
        viewModel.onLayoutChanged = { reportedKey = $0; reported = $1 }
        await viewModel.activate()
        defer { viewModel.deactivate() }

        viewModel.swapPositions(0, 4)

        XCTAssertEqual(viewModel.slots.map(\.number), [5, 2, 3, 4, 1, 6, 7, 8, 9])
        XCTAssertEqual(reported, [5, 2, 3, 4, 1, 6, 7, 8, 9])
        XCTAssertEqual(reportedKey, "main")
        // The slot keeps the real desktop, so switching still targets it.
        XCTAssertEqual(viewModel.slots[4].desktop?.number, 1)
    }

    func testNavigationFollowsGridPositionsNotDesktopNumbers() async {
        let viewModel = GridOverviewViewModel(
            spaceService: StubDesktopSpaceService(snapshot: makeSnapshot(count: 9)),
            layouts: ["main": [5, 2, 3, 4, 1, 6, 7, 8, 9]],
            accessibilityStatus: { true },
            screenRecordingStatus: { true }
        )
        viewModel.select(1)
        viewModel.moveSelection(.up)
        XCTAssertEqual(viewModel.selectedNumber, 2)
        viewModel.moveSelection(.left)
        XCTAssertEqual(viewModel.selectedNumber, 5)
    }

    func testLayoutIsKeptPerDisplay() async {
        func snapshot(display: String) -> DesktopSpaceSnapshot {
            var base = makeSnapshot(count: 9)
            base.displayID = display
            return base
        }
        let service = StubDesktopSpaceService(snapshot: snapshot(display: "A"))
        let viewModel = GridOverviewViewModel(
            spaceService: service,
            layouts: ["A": [5, 2, 3, 4, 1, 6, 7, 8, 9]],
            accessibilityStatus: { true },
            screenRecordingStatus: { true }
        )
        await viewModel.activate()
        defer { viewModel.deactivate() }
        XCTAssertEqual(viewModel.slots.map(\.number), [5, 2, 3, 4, 1, 6, 7, 8, 9])

        service.snapshot = snapshot(display: "B")
        await viewModel.reload()
        XCTAssertEqual(viewModel.slots.map(\.number), Array(1...9))
    }

    func testDragStateIsClearedBySwapAndDeactivate() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        await viewModel.activate()
        viewModel.beginDrag(0)
        viewModel.setDropTarget(3)
        viewModel.swapPositions(0, 3)
        XCTAssertNil(viewModel.draggingPosition)
        XCTAssertNil(viewModel.dropTargetPosition)

        viewModel.beginDrag(1)
        viewModel.deactivate()
        XCTAssertNil(viewModel.draggingPosition)
    }

    func testInvalidLayoutFallsBackToIdentity() {
        XCTAssertEqual(DesktopGridLayout.sanitized([1, 1, 3, 4, 5, 6, 7, 8, 9]), DesktopGridLayout.identity)
        XCTAssertEqual(DesktopGridLayout.sanitized([]), DesktopGridLayout.identity)
    }

    func testNineSlotsIncludeNotCreatedDesktops() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 5))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        XCTAssertEqual(viewModel.slots.count, 9)
        XCTAssertEqual(viewModel.slots.filter(\.isCreated).map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(viewModel.banners.notCreatedCount, 4)
    }

    func testSelectionStartsAtCurrentDesktopAndTargetFollowsSelection() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 6, current: 4))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        XCTAssertEqual(viewModel.currentNumber, 4)
        // activate() does not move the selection; the panel selects current on
        // first open via selectCurrentDesktop().
        viewModel.selectCurrentDesktop()
        XCTAssertEqual(viewModel.selectedNumber, 4)
        XCTAssertNil(viewModel.targetNumber)

        viewModel.select(9)
        XCTAssertEqual(viewModel.targetNumber, 9)
    }

    func testArrowSelectionClampsAtGridEdgesInsteadOfWrapping() {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))

        viewModel.select(1)
        viewModel.moveSelection(.left)
        XCTAssertEqual(viewModel.selectedNumber, 1)
        viewModel.moveSelection(.up)
        XCTAssertEqual(viewModel.selectedNumber, 1)

        viewModel.select(9)
        viewModel.moveSelection(.right)
        XCTAssertEqual(viewModel.selectedNumber, 9)
        viewModel.moveSelection(.down)
        XCTAssertEqual(viewModel.selectedNumber, 9)

        viewModel.select(5)
        viewModel.moveSelection(.left)
        XCTAssertEqual(viewModel.selectedNumber, 4)
        viewModel.moveSelection(.up)
        XCTAssertEqual(viewModel.selectedNumber, 1)
    }

    func testDirectSelectionOnlyCallsBackForCreatedDesktops() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 5))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        var switched: [Int] = []
        viewModel.onSwitchRequested = { desktop in switched.append(desktop.number) }

        viewModel.selectAndActivate(3)
        XCTAssertEqual(viewModel.selectedNumber, 3)
        XCTAssertEqual(switched, [3])

        viewModel.selectAndActivate(8) // not created
        XCTAssertEqual(viewModel.selectedNumber, 8)
        XCTAssertEqual(switched, [3], "A not-created desktop must not request a switch")
    }

    func testReturnOnSelectionRequestsSwitch() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        var switched: [Int] = []
        viewModel.onSwitchRequested = { switched.append($0.number) }
        viewModel.select(7)
        viewModel.activateSelection()

        XCTAssertEqual(switched, [7])
    }

    func testPermissionBannersFollowInjectedChecks() async {
        let viewModel = makeViewModel(
            snapshot: makeSnapshot(count: 9),
            accessibility: false,
            screenRecording: false
        )
        await viewModel.activate()
        defer { viewModel.deactivate() }

        XCTAssertTrue(viewModel.banners.accessibilityMissing)
        XCTAssertTrue(viewModel.banners.screenRecordingMissing)
        XCTAssertFalse(viewModel.banners.spacesUnavailable)
    }

    func testUnavailableSnapshotShowsBannerAndNoCreatedSlots() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 1, unavailable: true))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        XCTAssertTrue(viewModel.banners.spacesUnavailable)
        XCTAssertTrue(viewModel.slots.allSatisfy { !$0.isCreated })
        XCTAssertNil(viewModel.currentNumber)
        XCTAssertEqual(viewModel.selectedNumber, 1)
    }

    func testSelectionFallsBackToFirstSlotWhenNoDesktopsExist() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 1, unavailable: true))
        viewModel.select(7)
        await viewModel.activate()
        defer { viewModel.deactivate() }

        XCTAssertEqual(viewModel.selectedNumber, 1)
    }

    func testApplySettingsUpdatesStyleBackgroundAndLanguageWithoutReloadNoise() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        var settings = AppSettings.default
        settings.gridStyle = .b
        settings.gridBackground = .white
        settings.language = .simplifiedChinese
        viewModel.applySettings(settings)

        XCTAssertEqual(viewModel.style, .b)
        XCTAssertEqual(viewModel.background, .white)
        XCTAssertEqual(viewModel.language, .simplifiedChinese)
        XCTAssertEqual(viewModel.slots.count, 9)
    }

    func testThumbnailInterestCoversOnlyTheFirstThreeWindowsPerDesktop() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 3))
        await viewModel.activate()
        defer { viewModel.deactivate() }

        // Slot 1 has one window, slot 2 is empty, slot 3 has one window.
        XCTAssertEqual(viewModel.windowsShownByOverview, [1, 3])
    }

    // MARK: - T22: nothing runs while the overview is hidden

    func testTheRefreshTimerOnlyExistsWhileTheOverviewIsVisible() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        XCTAssertFalse(viewModel.isRefreshTimerActive)

        await viewModel.activate()
        XCTAssertTrue(viewModel.isRefreshTimerActive)
        XCTAssertTrue(viewModel.shouldCaptureThumbnails)

        viewModel.deactivate()
        XCTAssertFalse(viewModel.isRefreshTimerActive, "a hidden overview must not poll Spaces")
        XCTAssertFalse(viewModel.shouldCaptureThumbnails, "a hidden overview must not capture")
    }

    /// Ten open/close cycles must not leak timers: one timer per visible
    /// period, none afterwards.
    func testRepeatedActivateDeactivateLeavesNoTimerBehind() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        for _ in 0..<10 {
            await viewModel.activate()
            XCTAssertTrue(viewModel.isRefreshTimerActive)
            viewModel.deactivate()
            XCTAssertFalse(viewModel.isRefreshTimerActive)
        }
    }

    func testThumbnailCaptureAlsoStopsWithoutScreenRecording() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9), screenRecording: false)
        await viewModel.activate()
        defer { viewModel.deactivate() }

        XCTAssertTrue(viewModel.isRefreshTimerActive)
        XCTAssertFalse(viewModel.shouldCaptureThumbnails)
    }

    /// The reload that finishes after `deactivate()` must not touch state or
    /// leave the loading flag set (the panel is gone).
    func testAReloadFinishingAfterHideIsIgnored() async {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 4))
        viewModel.deactivate()
        await viewModel.reload()

        XCTAssertTrue(viewModel.snapshot.desktops.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - T21: keyboard path

    func testTabWalksTheNineCellsInVisualOrderAndWraps() {
        let viewModel = makeViewModel(snapshot: makeSnapshot(count: 9))
        viewModel.select(1)

        viewModel.focusAdjacent(forward: true)
        XCTAssertEqual(viewModel.selectedNumber, 2)
        viewModel.focusAdjacent(forward: true)
        XCTAssertEqual(viewModel.selectedNumber, 3)

        viewModel.select(9)
        viewModel.focusAdjacent(forward: true)
        XCTAssertEqual(viewModel.selectedNumber, 1, "Tab wraps from the last cell to the first")

        viewModel.select(1)
        viewModel.focusAdjacent(forward: false)
        XCTAssertEqual(viewModel.selectedNumber, 9, "Shift-Tab wraps backwards")
        viewModel.focusAdjacent(forward: false)
        XCTAssertEqual(viewModel.selectedNumber, 8)
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
}
