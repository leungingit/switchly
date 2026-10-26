//
//  DesktopGridCoordinatorTests.swift
//  SwitchlyTests
//
//  The listener only runs while the grid is enabled, repeated start/stop is
//  safe, and a second swipe cannot stack a navigation. Everything is faked.
//

import XCTest
import CoreGraphics
@testable import Switchly

private final class RecordingGestureService: TrackpadGestureServiceProtocol {
    var isAvailable = true
    var isRunning = false
    var onSwipe: ((TrackpadSwipeEvent) -> Void)?
    var onHold: ((FourFingerHoldEvent) -> Void)?
    var startResult = true
    var startCount = 0
    var stopCount = 0
    var systemState = SystemFourFingerGestureState(
        horizontalSwipeEnabled: false,
        verticalSwipeEnabled: false
    )

    @discardableResult
    func start() -> Bool {
        startCount += 1
        isRunning = startResult
        return startResult
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func systemGestureState() -> SystemFourFingerGestureState { systemState }
}

private final class RecordingInterceptor: SystemGestureIntercepting {
    var isIntercepting = false
    func start() -> Bool { isIntercepting = true; return true }
    func stop() { isIntercepting = false }
}

private final class CountingSpaceService: DesktopSpaceServiceProtocol {
    var snapshot: DesktopSpaceSnapshot
    private(set) var loadCount = 0

    init(snapshot: DesktopSpaceSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async -> DesktopSpaceSnapshot {
        loadCount += 1
        return snapshot
    }
}

@MainActor
private final class RecordingNavigation: DesktopNavigationServiceProtocol {
    var targets: [Int] = []

    func targetNumber(from current: Int, direction: SwipeDirection) -> Int? {
        GridHUDViewModel.target(from: current, direction: direction)
    }

    func navigate(to number: Int, snapshot: DesktopSpaceSnapshot) async -> DesktopNavigationResult {
        targets.append(number)
        return .switched(number: number, path: .applicationActivation, confirmed: true)
    }
}

@MainActor
final class DesktopGridCoordinatorTests: XCTestCase {

    private func snapshot(count: Int, current: Int) -> DesktopSpaceSnapshot {
        DesktopSpaceSnapshot(
            desktops: (1...count).map { number in
                Desktop(id: UInt64(number), number: number, isCurrent: number == current, windows: [])
            },
            availability: .available,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func settings(enabled: Bool) -> AppSettings {
        var settings = AppSettings.default
        settings.gridEnabled = enabled
        return settings
    }

    private func makeCoordinator(
        gestures: RecordingGestureService,
        navigation: RecordingNavigation,
        spaces: CountingSpaceService,
        interceptor: RecordingInterceptor = RecordingInterceptor()
    ) -> DesktopGridCoordinator {
        DesktopGridCoordinator(
            gestureService: gestures,
            navigation: navigation,
            spaceService: spaces,
            interceptor: interceptor
        )
    }

    func testListenerStaysStoppedWhileTheGridIsDisabled() {
        let gestures = RecordingGestureService()
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: RecordingNavigation(),
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        )

        coordinator.apply(settings: settings(enabled: false))

        XCTAssertEqual(gestures.startCount, 0)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testEnablingStartsOnceAndDisablingStops() {
        let gestures = RecordingGestureService()
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: RecordingNavigation(),
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        )

        coordinator.apply(settings: settings(enabled: true))
        coordinator.apply(settings: settings(enabled: true))
        XCTAssertEqual(gestures.startCount, 1, "repeated settings changes must not restart the listener")
        XCTAssertTrue(coordinator.isEnabled)

        coordinator.apply(settings: settings(enabled: false))
        XCTAssertEqual(gestures.stopCount, 1)
        XCTAssertFalse(coordinator.isEnabled)

        // Stopping an already stopped coordinator is a no-op.
        coordinator.apply(settings: settings(enabled: false))
        XCTAssertEqual(gestures.stopCount, 1)
    }

    func testFailedStartDoesNotMarkTheCoordinatorEnabled() {
        let gestures = RecordingGestureService()
        gestures.startResult = false
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: RecordingNavigation(),
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        )

        coordinator.apply(settings: settings(enabled: true))

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertNil(gestures.onSwipe)

        // A later retry is allowed.
        gestures.startResult = true
        coordinator.apply(settings: settings(enabled: true))
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertNotNil(gestures.onSwipe)
    }

    func testSwipeIsIgnoredWhenTheCoordinatorIsStopped() {
        let gestures = RecordingGestureService()
        let navigation = RecordingNavigation()
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: navigation,
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        )

        coordinator.apply(settings: settings(enabled: true))
        coordinator.apply(settings: settings(enabled: false))
        gestures.onSwipe?(
            TrackpadSwipeEvent(
                gesture: SwipeGesture(direction: .right, angleDegrees: 0, displacementMM: 18, fingers: 4, duration: 0.1),
                suppressed: false
            )
        )

        XCTAssertNil(gestures.onSwipe, "stopping must clear the handler")
        XCTAssertTrue(navigation.targets.isEmpty)
    }

    func testPanelSwitchGoesThroughTheSameNavigationService() async {
        let navigation = RecordingNavigation()
        let spaces = CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        let coordinator = makeCoordinator(
            gestures: RecordingGestureService(),
            navigation: navigation,
            spaces: spaces
        )

        let result = await coordinator.switchToDesktop(number: 4)

        XCTAssertEqual(navigation.targets, [4])
        XCTAssertEqual(spaces.loadCount, 1)
        XCTAssertEqual(result, .switched(number: 4, path: .applicationActivation, confirmed: true))
    }

    // MARK: - T17 / R10: the listener state drives the panels

    func testListenerStateCallbackFollowsStartAndStop() {
        let gestures = RecordingGestureService()
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: RecordingNavigation(),
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        )
        var states: [Bool] = []
        coordinator.onListenerStateChanged = { states.append($0) }

        coordinator.apply(settings: settings(enabled: true))
        XCTAssertEqual(states, [true])

        // A repeated enable is a no-op: the panels are not told to reopen.
        coordinator.apply(settings: settings(enabled: true))
        XCTAssertEqual(states, [true])

        coordinator.apply(settings: settings(enabled: false))
        XCTAssertEqual(states, [true, false])

        // Disabling twice does not emit a second "stopped".
        coordinator.apply(settings: settings(enabled: false))
        XCTAssertEqual(states, [true, false])
    }

    /// A failed start must still notify, so a panel opened by a stale menu
    /// entry closes again instead of showing a grid that cannot switch.
    func testFailedStartReportsNotRunning() {
        let gestures = RecordingGestureService()
        gestures.startResult = false
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: RecordingNavigation(),
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        )
        var states: [Bool] = []
        coordinator.onListenerStateChanged = { states.append($0) }

        coordinator.apply(settings: settings(enabled: true))

        XCTAssertEqual(states, [false])
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testThreeFingerSwipeDownRequestsTheOverviewOnly() {
        let gestures = RecordingGestureService()
        let navigation = RecordingNavigation()
        let spaces = CountingSpaceService(snapshot: snapshot(count: 9, current: 1))
        let coordinator = makeCoordinator(gestures: gestures, navigation: navigation, spaces: spaces)
        var requests = 0
        coordinator.onOverviewRequested = { requests += 1 }
        coordinator.apply(settings: settings(enabled: true))

        func send(_ direction: SwipeDirection) {
            gestures.onSwipe?(TrackpadSwipeEvent(
                gesture: SwipeGesture(direction: direction, angleDegrees: 270, displacementMM: 18, fingers: 5, duration: 0.1),
                suppressed: false
            ))
        }
        send(.down)
        send(.up)
        XCTAssertEqual(requests, 1, "only a downward five-finger swipe opens the overview")
        XCTAssertEqual(spaces.loadCount, 0)
        XCTAssertTrue(navigation.targets.isEmpty)

        var off = settings(enabled: true)
        off.gridOverviewGestureEnabled = false
        coordinator.apply(settings: off)
        send(.down)
        XCTAssertEqual(requests, 1, "the switch turns the gesture off")
    }

    func testInterceptionFollowsTheGridAndItsSwitch() {
        let gestures = RecordingGestureService()
        let interceptor = RecordingInterceptor()
        let coordinator = makeCoordinator(
            gestures: gestures,
            navigation: RecordingNavigation(),
            spaces: CountingSpaceService(snapshot: snapshot(count: 9, current: 1)),
            interceptor: interceptor
        )
        var missionControl = 0
        coordinator.onMissionControlRequested = { missionControl += 1 }

        coordinator.apply(settings: settings(enabled: true))
        XCTAssertTrue(interceptor.isIntercepting)
        gestures.onSwipe?(TrackpadSwipeEvent(
            gesture: SwipeGesture(direction: .up, angleDegrees: 90, displacementMM: 18, fingers: 5, duration: 0.1),
            suppressed: false
        ))
        XCTAssertEqual(missionControl, 1, "five-finger up stands in for the swallowed system gesture")

        var off = settings(enabled: true)
        off.gridInterceptSystemGestures = false
        coordinator.apply(settings: off)
        XCTAssertFalse(interceptor.isIntercepting)
        gestures.onSwipe?(TrackpadSwipeEvent(
            gesture: SwipeGesture(direction: .up, angleDegrees: 90, displacementMM: 18, fingers: 5, duration: 0.1),
            suppressed: false
        ))
        XCTAssertEqual(missionControl, 1, "without interception the system keeps its own gesture")

        coordinator.apply(settings: settings(enabled: true))
        coordinator.apply(settings: settings(enabled: false))
        XCTAssertFalse(interceptor.isIntercepting, "disabling the grid restores the system gestures")
    }
}
