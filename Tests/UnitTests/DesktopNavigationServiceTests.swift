//
//  DesktopNavigationServiceTests.swift
//  SwitchlyTests
//
//  Navigation mapping, path selection (activation vs. system hotkey), the
//  hotkey lookup against the live global order, and the prerequisite model.
//  Every system call is faked.
//

import XCTest
import CoreGraphics
@testable import Switchly

private final class FakeSwitcher: DesktopSwitching {
    var activatedPIDs: [pid_t] = []
    var postedBindings: [DesktopHotKeyBinding] = []
    var activationError: Error?
    var postSucceeds = true

    func activateApplication(pid: pid_t) async throws {
        if let activationError { throw activationError }
        activatedPIDs.append(pid)
    }

    func postSystemHotKey(_ binding: DesktopHotKeyBinding) -> Bool {
        guard postSucceeds else { return false }
        postedBindings.append(binding)
        return true
    }
}

private final class FakeHotKeyReader: DesktopHotKeyReading {
    var bindings: DesktopHotKeyBindings = .empty
    func readBindings() -> DesktopHotKeyBindings { bindings }
}

private final class FakeOrderReader: DesktopSpaceOrderReading {
    var order: [UInt64] = []
    func globalOrdinarySpaceOrder() async -> [UInt64] { order }
}

/// Answers the closed-loop confirmation a fixed number of times before
/// reporting success, so the polling budget can be exercised.
private final class ScriptedConfirmer: DesktopSwitchConfirming {
    /// How many calls report failure before it starts returning true.
    var failuresBeforeSuccess: Int
    /// When true the switch never confirms.
    var neverConfirms = false
    private(set) var callCount = 0
    private(set) var lastWindowIDs: Set<CGWindowID> = []
    private(set) var lastOwnerPID: pid_t?

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func confirm(number: Int, windowIDs: Set<CGWindowID>, ownerPID: pid_t?) async -> Bool {
        callCount += 1
        lastWindowIDs = windowIDs
        lastOwnerPID = ownerPID
        if neverConfirms { return false }
        if callCount <= failuresBeforeSuccess { return false }
        return true
    }
}

final class DesktopNavigationServiceTests: XCTestCase {

    private func snapshot(
        desktops: [(number: Int, id: UInt64, current: Bool, pids: [pid_t])]
    ) -> DesktopSpaceSnapshot {
        DesktopSpaceSnapshot(
            desktops: desktops.map { entry in
                Desktop(
                    id: entry.id,
                    number: entry.number,
                    isCurrent: entry.current,
                    windows: entry.pids.map { window($0) }
                )
            },
            availability: .available,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeService(
        switcher: FakeSwitcher,
        hotKeys: FakeHotKeyReader = FakeHotKeyReader(),
        order: FakeOrderReader = FakeOrderReader(),
        confirmer: ScriptedConfirmer = ScriptedConfirmer()
    ) -> DesktopNavigationService {
        DesktopNavigationService(
            switcher: switcher,
            hotKeys: hotKeys,
            order: order,
            confirmer: confirmer
        )
    }

    // MARK: - Mapping

    func testSwipeMappingStaysInsideTheNineCellGrid() {
        let service = makeService(switcher: FakeSwitcher())

        XCTAssertEqual(service.targetNumber(from: 5, direction: .upRight), 3)
        XCTAssertEqual(service.targetNumber(from: 5, direction: .downLeft), 7)
        XCTAssertEqual(service.targetNumber(from: 4, direction: .left), nil)
        XCTAssertEqual(service.targetNumber(from: 2, direction: .up), nil)
        XCTAssertEqual(service.targetNumber(from: 1, direction: .down), 4)
        XCTAssertNil(service.targetNumber(from: 12, direction: .right))
    }

    // MARK: - Path selection

    func testDesktopWithWindowsActivatesItsFrontmostApp() async {
        let switcher = FakeSwitcher()
        let service = makeService(switcher: switcher)
        let initial = snapshot(desktops: [(1, 10, true, []), (2, 20, false, [555, 666])])

        let result = await service.navigate(to: 2, snapshot: initial)

        XCTAssertEqual(switcher.activatedPIDs, [555])
        XCTAssertTrue(switcher.postedBindings.isEmpty)
        XCTAssertEqual(result, .switched(number: 2, path: .applicationActivation, confirmed: true))
    }

    func testEmptyDesktopUsesTheSystemHotKeyWithTheLiveBinding() async {
        let switcher = FakeSwitcher()
        let hotKeys = FakeHotKeyReader()
        hotKeys.bindings = DesktopHotKeyBindings(bindings: [
            3: DesktopHotKeyBinding(keyCode: 20, modifiers: 262_144),
        ])
        let order = FakeOrderReader()
        order.order = [10, 11, 20]
        let service = makeService(
            switcher: switcher,
            hotKeys: hotKeys,
            order: order
        )
        let initial = snapshot(desktops: [
            (1, 10, true, []),
            (2, 11, false, []),
            (3, 20, false, []),
        ])

        let result = await service.navigate(to: 3, snapshot: initial)

        XCTAssertTrue(switcher.activatedPIDs.isEmpty)
        XCTAssertEqual(switcher.postedBindings, [DesktopHotKeyBinding(keyCode: 20, modifiers: 262_144)])
        XCTAssertEqual(result, .switched(number: 3, path: .systemHotKey, confirmed: true))
    }

    func testReboundHotKeyIsReadFromPreferencesInsteadOfHardCodingControlDigit() async {
        let switcher = FakeSwitcher()
        let hotKeys = FakeHotKeyReader()
        // The user rebound desktop 2 to ⌥⌘K.
        hotKeys.bindings = DesktopHotKeyBindings(bindings: [
            2: DesktopHotKeyBinding(keyCode: 40, modifiers: 1_572_864),
        ])
        let order = FakeOrderReader()
        order.order = [10, 20]
        let service = makeService(
            switcher: switcher,
            hotKeys: hotKeys,
            order: order
        )

        _ = await service.navigate(
            to: 2,
            snapshot: snapshot(desktops: [(1, 10, true, []), (2, 20, false, [])])
        )

        XCTAssertEqual(switcher.postedBindings.first?.keyCode, 40)
        XCTAssertEqual(switcher.postedBindings.first?.modifiers, 1_572_864)
    }

    func testHotKeyNumberUsesTheGlobalOrderNotTheGridNumber() async {
        let switcher = FakeSwitcher()
        let hotKeys = FakeHotKeyReader()
        // Only global desktop 5 is configured; the grid number here is 2.
        hotKeys.bindings = DesktopHotKeyBindings(bindings: [
            5: DesktopHotKeyBinding(keyCode: 23, modifiers: 262_144),
        ])
        let order = FakeOrderReader()
        // Display 1 owns two spaces, display 2 owns three: the second grid
        // desktop of display 2 is global number 5.
        order.order = [10, 11, 20, 21, 30]
        let service = makeService(
            switcher: switcher,
            hotKeys: hotKeys,
            order: order
        )

        let result = await service.navigate(
            to: 2,
            snapshot: snapshot(desktops: [(1, 10, true, []), (2, 30, false, [])])
        )

        XCTAssertEqual(switcher.postedBindings.first?.keyCode, 23)
        XCTAssertEqual(result, .switched(number: 2, path: .systemHotKey, confirmed: true))
    }

    func testMissingHotKeyFailsWithoutPostingAnything() async {
        let switcher = FakeSwitcher()
        let service = makeService(switcher: switcher)

        let result = await service.navigate(
            to: 2,
            snapshot: snapshot(desktops: [(1, 10, true, []), (2, 20, false, [])])
        )

        XCTAssertEqual(result, .failed(reason: "hotkey_not_configured"))
        XCTAssertTrue(switcher.postedBindings.isEmpty)
    }

    func testDeniedEventPostReportsFailure() async {
        let switcher = FakeSwitcher()
        switcher.postSucceeds = false
        let hotKeys = FakeHotKeyReader()
        hotKeys.bindings = DesktopHotKeyBindings(bindings: [
            2: DesktopHotKeyBinding(keyCode: 19, modifiers: 262_144),
        ])
        let order = FakeOrderReader()
        order.order = [10, 20]
        let service = makeService(
            switcher: switcher,
            hotKeys: hotKeys,
            order: order
        )

        let result = await service.navigate(
            to: 2,
            snapshot: snapshot(desktops: [(1, 10, true, []), (2, 20, false, [])])
        )

        XCTAssertEqual(result, .failed(reason: "event_post_denied"))
    }

    func testNotCreatedTargetIsRejectedBeforeAnySystemCall() async {
        let switcher = FakeSwitcher()
        let service = makeService(switcher: switcher)

        let result = await service.navigate(
            to: 5,
            snapshot: snapshot(desktops: [(1, 10, true, [])])
        )

        XCTAssertEqual(result, .notCreated(number: 5))
        XCTAssertTrue(switcher.activatedPIDs.isEmpty)
    }

    func testTargetAlreadyCurrentConfirmsWithoutSwitching() async {
        let switcher = FakeSwitcher()
        let service = makeService(switcher: switcher)

        let result = await service.navigate(
            to: 1,
            snapshot: snapshot(desktops: [(1, 10, true, [])])
        )

        XCTAssertEqual(result, .switched(number: 1, path: .unavailable, confirmed: true))
        XCTAssertTrue(switcher.activatedPIDs.isEmpty)
        XCTAssertTrue(switcher.postedBindings.isEmpty)
    }

    func testActivationFailureIsReported() async {
        let switcher = FakeSwitcher()
        switcher.activationError = SwitchError.applicationNotFound
        let service = makeService(switcher: switcher)

        let result = await service.navigate(
            to: 2,
            snapshot: snapshot(desktops: [(1, 10, true, []), (2, 20, false, [777])])
        )

        XCTAssertEqual(result, .failed(reason: "activation_failed"))
    }

    // MARK: - Confirmation

    func testSwitchIsNotConfirmedWhenTheDesktopNeverArrives() async {
        let switcher = FakeSwitcher()
        let confirmer = ScriptedConfirmer()
        confirmer.neverConfirms = true
        let service = makeService(switcher: switcher, confirmer: confirmer)
        let initial = snapshot(desktops: [(1, 10, true, []), (2, 20, false, [555])])

        let result = await service.navigate(to: 2, snapshot: initial)

        guard case .switched(_, _, let confirmed) = result else {
            return XCTFail("expected a switched result, got \(result)")
        }
        XCTAssertFalse(confirmed, "a switch that never arrives must not be reported as confirmed")
        XCTAssertGreaterThan(confirmer.callCount, 1, "the loop must retry inside its budget")
    }

    func testConfirmationChecksTheTargetWindowsAndTheActivatedApp() async {
        let switcher = FakeSwitcher()
        let confirmer = ScriptedConfirmer(failuresBeforeSuccess: 2)
        let service = makeService(switcher: switcher, confirmer: confirmer)
        let initial = snapshot(desktops: [(1, 10, true, []), (2, 20, false, [555, 666])])

        let result = await service.navigate(to: 2, snapshot: initial)

        XCTAssertEqual(result, .switched(number: 2, path: .applicationActivation, confirmed: true))
        XCTAssertEqual(confirmer.callCount, 3)
        XCTAssertEqual(confirmer.lastWindowIDs, [555, 666])
        XCTAssertEqual(confirmer.lastOwnerPID, 555)
    }

    func testEmptyDesktopConfirmsWithoutAWindowOrApp() async {
        let switcher = FakeSwitcher()
        let hotKeys = FakeHotKeyReader()
        hotKeys.bindings = DesktopHotKeyBindings(bindings: [
            2: DesktopHotKeyBinding(keyCode: 19, modifiers: 262_144),
        ])
        let order = FakeOrderReader()
        order.order = [10, 20]
        let confirmer = ScriptedConfirmer()
        let service = makeService(switcher: switcher, hotKeys: hotKeys, order: order, confirmer: confirmer)

        _ = await service.navigate(
            to: 2,
            snapshot: snapshot(desktops: [(1, 10, true, []), (2, 20, false, [])])
        )

        XCTAssertTrue(confirmer.lastWindowIDs.isEmpty)
        XCTAssertNil(confirmer.lastOwnerPID)
    }

    func testHotKeyModifiersConvertToEventFlags() {
        // 262144 is what the system plist stores for Control.
        let flags = SystemDesktopSwitcher.flags(fromHotKeyModifiers: 262_144)
        XCTAssertTrue(flags.contains(.maskControl))
        XCTAssertFalse(flags.contains(.maskCommand))

        // Control + Option + Shift + Command.
        let mixed = SystemDesktopSwitcher.flags(fromHotKeyModifiers: 262_144 | 524_288 | 131_072 | 1_048_576)
        XCTAssertTrue(mixed.contains(.maskControl))
        XCTAssertTrue(mixed.contains(.maskCommand))
        XCTAssertTrue(mixed.contains(.maskAlternate))
        XCTAssertTrue(mixed.contains(.maskShift))
    }

    // MARK: - Prerequisites

    func testPrerequisiteSnapshotCountsMetItemsAndFlagsBlockers() {
        let states: [GridPrerequisite: GridPrerequisiteState] = [
            .accessibility: .met,
            .screenRecording: .unmet,
            .twoDesktops: .met,
            .desktopHotKeys: .met,
            .gestureAvailability: .met,
        ]
        let snapshot = GridPrerequisiteSnapshot(states: states)

        XCTAssertEqual(snapshot.metCount, 4)
        // Screen recording does not block gestures; it only simplifies previews.
        XCTAssertFalse(snapshot.gesturesBlocked)
        XCTAssertEqual(snapshot.unmetItems, [.screenRecording])

        let blocked = GridPrerequisiteSnapshot(states: states.merging([
            .accessibility: .unmet,
        ]) { _, new in new })
        XCTAssertTrue(blocked.gesturesBlocked)
    }

    func testUnknownPrerequisiteDefaultsToUndetectable() {
        let snapshot = GridPrerequisiteSnapshot(states: [:])
        XCTAssertEqual(snapshot.state(of: .accessibility), .undetectable)
        XCTAssertEqual(snapshot.metCount, 0)
    }

    // MARK: - Helpers

    private func window(_ pid: pid_t) -> WindowInfo {
        WindowInfo(
            id: CGWindowID(pid),
            ownerPID: pid,
            ownerName: "App \(pid)",
            windowTitle: "Window \(pid)",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: false,
            windowNumber: Int(pid)
        )
    }
}

final class SystemDesktopHotKeyReaderTests: XCTestCase {
    func testAbsentEntriesFallBackToSystemDefaultControlDigit() {
        let bindings = SystemDesktopHotKeyReader.bindings(from: [:])

        XCTAssertTrue(bindings.isAvailable)
        XCTAssertEqual(bindings[1], DesktopHotKeyBinding(keyCode: 18, modifiers: 262144))
        XCTAssertEqual(bindings[9], DesktopHotKeyBinding(keyCode: 25, modifiers: 262144))
    }

    func testExplicitlyDisabledEntryStaysDisabled() {
        let stored: [String: Any] = (118...126).reduce(into: [:]) { $0[String($1)] = ["enabled": false] }

        XCTAssertFalse(SystemDesktopHotKeyReader.bindings(from: stored).isAvailable)
    }

    func testCustomBindingIsKept() {
        let stored: [String: Any] = [
            "118": ["enabled": true, "value": ["parameters": [65535, 122, 524288], "type": "standard"]],
        ]

        XCTAssertEqual(SystemDesktopHotKeyReader.bindings(from: stored)[1],
                       DesktopHotKeyBinding(keyCode: 122, modifiers: 524288))
    }
}
