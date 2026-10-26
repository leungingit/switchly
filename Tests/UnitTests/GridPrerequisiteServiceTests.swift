//
//  GridPrerequisiteServiceTests.swift
//  SwitchlyTests
//
//  The service maps injected signals to the shared snapshot. Every input is
//  faked, so no Accessibility, Screen Recording or trackpad state is read.
//

import XCTest
@testable import Switchly

private final class StubGestureService: TrackpadGestureServiceProtocol {
    var isAvailable = true
    var isRunning = false
    var onSwipe: ((TrackpadSwipeEvent) -> Void)?
    var onHold: ((FourFingerHoldEvent) -> Void)?
    var systemState = SystemFourFingerGestureState(
        horizontalSwipeEnabled: false,
        verticalSwipeEnabled: false
    )

    @discardableResult
    func start() -> Bool { isRunning = true; return true }
    func stop() { isRunning = false }
    func systemGestureState() -> SystemFourFingerGestureState { systemState }
}

private final class StubHotKeyReader: DesktopHotKeyReading {
    var bindings: DesktopHotKeyBindings = .empty
    func readBindings() -> DesktopHotKeyBindings { bindings }
}

final class GridPrerequisiteServiceTests: XCTestCase {

    private func makeService(
        accessibility: Bool = true,
        screenRecording: Bool = true,
        gestures: StubGestureService = StubGestureService(),
        hotKeys: StubHotKeyReader = StubHotKeyReader()
    ) -> GridPrerequisiteService {
        GridPrerequisiteService(
            accessibilityStatus: { accessibility },
            screenRecordingStatus: { screenRecording },
            gestureService: gestures,
            hotKeyReader: hotKeys
        )
    }

    private func hotKeys(withBindings: Bool) -> StubHotKeyReader {
        let reader = StubHotKeyReader()
        if withBindings {
            reader.bindings = DesktopHotKeyBindings(
                bindings: [1: DesktopHotKeyBinding(keyCode: 18, modifiers: 262_144)]
            )
        }
        return reader
    }

    func testEverythingMetWhenSignalsAreClean() {
        let snapshot = makeService(hotKeys: hotKeys(withBindings: true)).snapshot(spaceCount: 3)

        XCTAssertEqual(snapshot.metCount, 5)
        XCTAssertFalse(snapshot.gesturesBlocked)
        XCTAssertTrue(snapshot.unmetItems.isEmpty)
    }

    func testPermissionsAreReportedSeparately() {
        let noAccessibility = makeService(accessibility: false, hotKeys: hotKeys(withBindings: true))
            .snapshot(spaceCount: 2)
        XCTAssertEqual(noAccessibility.state(of: .accessibility), .unmet)
        XCTAssertEqual(noAccessibility.state(of: .screenRecording), .met)

        let noCapture = makeService(screenRecording: false, hotKeys: hotKeys(withBindings: true))
            .snapshot(spaceCount: 2)
        XCTAssertEqual(noCapture.state(of: .accessibility), .met)
        XCTAssertEqual(noCapture.state(of: .screenRecording), .unmet)
        // Screen Recording only degrades previews; it must not stop gestures.
        XCTAssertFalse(noCapture.gesturesBlocked)
    }

    func testOneDesktopFailsTheTwoDesktopRequirement() {
        let service = makeService(hotKeys: hotKeys(withBindings: true))
        XCTAssertEqual(service.snapshot(spaceCount: 1).state(of: .twoDesktops), .unmet)
        XCTAssertEqual(service.snapshot(spaceCount: 2).state(of: .twoDesktops), .met)
        XCTAssertEqual(service.snapshot(spaceCount: 9).state(of: .twoDesktops), .met)
    }

    func testMissingGestureFrameworkIsReportedAsUnmet() {
        let gestures = StubGestureService()
        gestures.isAvailable = false
        let snapshot = makeService(gestures: gestures, hotKeys: hotKeys(withBindings: true))
            .snapshot(spaceCount: 3)

        XCTAssertEqual(snapshot.state(of: .gestureAvailability), .unmet)
        XCTAssertTrue(snapshot.gesturesBlocked)
    }

    /// Empty desktops are reached with the system hotkey, so at least one
    /// binding has to be enabled for the keyboard path to exist.
    func testMissingDesktopHotKeysAreReportedButDoNotBlockGestures() {
        let snapshot = makeService(hotKeys: hotKeys(withBindings: false)).snapshot(spaceCount: 3)

        XCTAssertEqual(snapshot.state(of: .desktopHotKeys), .unmet)
        XCTAssertFalse(snapshot.gesturesBlocked)
        XCTAssertEqual(snapshot.metCount, 4)
    }

    func testTheSameServiceProducesTheSameSnapshotForBothSurfaces() {
        let service = makeService(accessibility: false, hotKeys: hotKeys(withBindings: false))
        let first = service.snapshot(spaceCount: 4)
        let second = service.snapshot(spaceCount: 4)

        XCTAssertEqual(first, second, "settings and onboarding must not disagree")
        XCTAssertEqual(first.summary(language: .english), "3 of 5 met")
    }
}
