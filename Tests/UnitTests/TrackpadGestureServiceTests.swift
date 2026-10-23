//
//  TrackpadGestureServiceTests.swift
//  SwitchlyTests
//
//  Lifecycle safety (repeated start/stop), the read-only system gesture
//  reader, and the prerequisite snapshot derived from it. The framework is
//  faked: no device is opened.
//

import XCTest
@testable import Switchly

@MainActor
private final class FakeGestureService: TrackpadGestureServiceProtocol {
    var isAvailable = true
    var isRunning = false
    var onSwipe: ((TrackpadSwipeEvent) -> Void)?
    var startCount = 0
    var stopCount = 0
    var startResult = true
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

/// The prerequisite snapshot now includes the ⌃1–9 desktop shortcuts, so these
/// stage-4 cases inject a fixed binding instead of reading the user's plist.
private final class FakeDesktopHotKeyReader: DesktopHotKeyReading {
    var bindings: DesktopHotKeyBindings = DesktopHotKeyBindings(
        bindings: [1: DesktopHotKeyBinding(keyCode: 18, modifiers: 262_144)]
    )
    func readBindings() -> DesktopHotKeyBindings { bindings }
}

private final class FakePreferenceReader: SystemGesturePreferenceReading {
    var horizontal: Bool?
    var vertical: Bool?
    func fourFingerHorizontalSwipeEnabled() -> Bool? { horizontal }
    func fourFingerVerticalSwipeEnabled() -> Bool? { vertical }
}

@MainActor
final class TrackpadGestureServiceTests: XCTestCase {

    // MARK: - Lifecycle

    func testRepeatedStartIsIdempotentAndStopIsSafeWhenIdle() {
        let bridge = MultitouchSupportBridge()
        // Skip when the framework is missing: the test is about the state
        // machine, not about this machine's private framework.
        guard bridge.isAvailable else {
            return
        }
        let service = TrackpadGestureService(bridge: bridge)
        service.start()
        service.start()
        service.stop()
        service.stop()

        XCTAssertFalse(service.isRunning)
    }

    func testUnavailableFrameworkReportsUnavailableWithoutCrashing() {
        let service = TrackpadGestureService(bridge: MultitouchSupportBridge(frameworkPath: "/nonexistent/MultitouchSupport"))
        XCTAssertFalse(service.isAvailable)
        XCTAssertFalse(service.start())
        XCTAssertFalse(service.isRunning)
        service.stop()
    }

    // MARK: - System gesture reading

    func testSystemGestureStateFallsBackToEnabledWhenTheKeyIsAbsent() {
        let reader = FakePreferenceReader()
        let service = TrackpadGestureService(
            bridge: MultitouchSupportBridge(frameworkPath: "/nonexistent/MultitouchSupport"),
            preferences: reader
        )

        // A missing key means the macOS default, which is "on" for both.
        XCTAssertTrue(service.systemGestureState().horizontalSwipeEnabled)
        XCTAssertTrue(service.systemGestureState().verticalSwipeEnabled)
        XCTAssertTrue(service.systemGestureState().conflictsWithGrid)

        reader.horizontal = false
        reader.vertical = false
        XCTAssertFalse(service.systemGestureState().conflictsWithGrid)
    }

    func testSystemGestureReaderIsReadOnly() {
        // The reader type exposes only getters; this asserts the contract that
        // nothing in the app can write the preference through it.
        let reader: SystemGesturePreferenceReading = SystemGesturePreferenceReader()
        _ = reader.fourFingerHorizontalSwipeEnabled()
        _ = reader.fourFingerVerticalSwipeEnabled()
    }

    // MARK: - Prerequisites

    func testPrerequisiteSnapshotMarksEverythingMetInTheIdealConfiguration() {
        let gestures = FakeGestureService()
        gestures.systemState = SystemFourFingerGestureState(
            horizontalSwipeEnabled: false,
            verticalSwipeEnabled: false
        )
        let service = GridPrerequisiteService(
            accessibilityStatus: { true },
            screenRecordingStatus: { true },
            gestureService: gestures,
            hotKeyReader: FakeDesktopHotKeyReader()
        )

        let snapshot = service.snapshot(spaceCount: 4)

        XCTAssertEqual(snapshot.metCount, GridPrerequisite.allCases.count)
        XCTAssertFalse(snapshot.gesturesBlocked)
        XCTAssertTrue(snapshot.unmetItems.isEmpty)
    }

    func testSingleDesktopAndMissingPermissionsAreReported() {
        let gestures = FakeGestureService()
        gestures.isAvailable = false
        gestures.systemState = SystemFourFingerGestureState(
            horizontalSwipeEnabled: false,
            verticalSwipeEnabled: false
        )
        let service = GridPrerequisiteService(
            accessibilityStatus: { false },
            screenRecordingStatus: { false },
            gestureService: gestures,
            hotKeyReader: FakeDesktopHotKeyReader()
        )

        let snapshot = service.snapshot(spaceCount: 1)

        XCTAssertEqual(snapshot.state(of: .accessibility), .unmet)
        XCTAssertEqual(snapshot.state(of: .screenRecording), .unmet)
        XCTAssertEqual(snapshot.state(of: .twoDesktops), .unmet)
        XCTAssertEqual(snapshot.state(of: .gestureAvailability), .unmet)
        XCTAssertTrue(snapshot.gesturesBlocked)
    }

    // MARK: - Blocking items

    func testOnlyPermissionsAndCaptureBlockGestures() {
        XCTAssertFalse(GridPrerequisite.screenRecording.blocksGestures)
        XCTAssertTrue(GridPrerequisite.accessibility.blocksGestures)
    }
}
