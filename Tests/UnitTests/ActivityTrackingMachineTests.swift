import XCTest
@testable import Switchly

final class ActivityTrackingMachineTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let safari = ActivityApp(bundleID: "com.apple.Safari", name: "Safari")
    private let notes = ActivityApp(bundleID: "com.apple.Notes", name: "Notes")

    private func update(
        _ machine: inout ActivityTrackingMachine,
        app: ActivityApp?,
        seconds: TimeInterval,
        uptime: TimeInterval,
        idleSeconds: TimeInterval = 0,
        blockers: Set<ActivityBlocker> = [],
        enabled: Bool = true
    ) -> ActivityMutation {
        machine.update(
            app: app,
            at: baseDate.addingTimeInterval(seconds),
            uptime: uptime,
            idleSeconds: idleSeconds,
            blockers: blockers,
            enabled: enabled
        )
    }

    func testRepeatedForegroundNotificationsUpdateOneCheckpoint() {
        var machine = ActivityTrackingMachine()

        let opened = update(&machine, app: safari, seconds: 0, uptime: 100)
        XCTAssertEqual(opened.sessions.count, 1)
        XCTAssertEqual(opened.sessions[0].endReason, .checkpoint)
        XCTAssertEqual(opened.sessions[0].seconds, 0)
        XCTAssertEqual(machine.current?.id, opened.sessions[0].id)

        let checked = update(&machine, app: safari, seconds: 10, uptime: 110, idleSeconds: 1)
        XCTAssertEqual(checked.sessions.count, 1)
        XCTAssertEqual(checked.sessions[0].id, opened.sessions[0].id)
        XCTAssertEqual(checked.sessions[0].end, baseDate.addingTimeInterval(10))
        XCTAssertEqual(checked.sessions[0].seconds, 10)
        XCTAssertEqual(machine.current?.id, opened.sessions[0].id)
    }

    func testSwitchClosesOldSessionAndOpensNonOverlappingCheckpoint() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 100)
        let switched = update(&machine, app: notes, seconds: 10, uptime: 110)

        XCTAssertEqual(switched.sessions.count, 2)
        XCTAssertEqual(switched.sessions[0].bundleID, safari.bundleID)
        XCTAssertEqual(switched.sessions[0].endReason, .switched)
        XCTAssertEqual(switched.sessions[0].start, baseDate)
        XCTAssertEqual(switched.sessions[0].end, baseDate.addingTimeInterval(10))
        XCTAssertEqual(switched.sessions[0].seconds, 10)

        XCTAssertEqual(switched.sessions[1].bundleID, notes.bundleID)
        XCTAssertEqual(switched.sessions[1].endReason, .checkpoint)
        XCTAssertEqual(switched.sessions[1].start, baseDate.addingTimeInterval(10))
        XCTAssertEqual(switched.sessions[1].end, baseDate.addingTimeInterval(10))
        XCTAssertEqual(switched.sessions[1].seconds, 0)
        XCTAssertFalse(
            switched.sessions[0].start <= switched.sessions[1].end
                && switched.sessions[1].start < switched.sessions[0].end
        )
        XCTAssertEqual(machine.current?.id, switched.sessions[1].id)
    }

    func testSleepBlockedAndDisabledIntervalsReceiveNoMonotonicSeconds() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 100)
        let blocked = update(
            &machine,
            app: safari,
            seconds: 10,
            uptime: 110,
            blockers: [.sleeping]
        )
        XCTAssertEqual(blocked.sessions.count, 1)
        XCTAssertEqual(blocked.sessions[0].endReason, .blocked)
        XCTAssertEqual(blocked.sessions[0].seconds, 10)
        XCTAssertNil(machine.current)

        let stillBlocked = update(
            &machine,
            app: safari,
            seconds: 40,
            uptime: 110,
            blockers: [.sleeping]
        )
        XCTAssertTrue(stillBlocked.sessions.isEmpty)

        let recovered = update(&machine, app: safari, seconds: 50, uptime: 115)
        XCTAssertEqual(recovered.sessions.count, 1)
        XCTAssertEqual(recovered.sessions[0].seconds, 0)

        let disabled = update(&machine, app: safari, seconds: 60, uptime: 125, enabled: false)
        XCTAssertEqual(disabled.sessions.count, 1)
        XCTAssertEqual(disabled.sessions[0].endReason, .disabled)
        XCTAssertEqual(disabled.sessions[0].seconds, 10)

        let stillDisabled = update(&machine, app: safari, seconds: 70, uptime: 135, enabled: false)
        XCTAssertTrue(stillDisabled.sessions.isEmpty)

        let enabled = update(&machine, app: safari, seconds: 80, uptime: 136)
        XCTAssertEqual(enabled.sessions.count, 1)
        XCTAssertEqual(enabled.sessions[0].seconds, 0)
    }

    func testIdleThresholdTruncatesAtLastInputOnlyOnceThenRecovers() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 0)

        let idle = update(
            &machine,
            app: safari,
            seconds: 300,
            uptime: 300,
            idleSeconds: 300
        )
        XCTAssertEqual(idle.sessions.count, 1)
        XCTAssertEqual(idle.sessions[0].endReason, .idle)
        XCTAssertEqual(idle.sessions[0].end, baseDate)
        XCTAssertEqual(idle.sessions[0].seconds, 0)
        XCTAssertEqual(idle.truncateAfter, baseDate)
        XCTAssertNil(machine.current)

        let repeated = update(
            &machine,
            app: safari,
            seconds: 310,
            uptime: 310,
            idleSeconds: 310
        )
        XCTAssertTrue(repeated.sessions.isEmpty)
        XCTAssertNil(repeated.truncateAfter)

        let recovered = update(&machine, app: safari, seconds: 311, uptime: 311, idleSeconds: 1)
        XCTAssertEqual(recovered.sessions.count, 1)
        XCTAssertEqual(recovered.sessions[0].start, baseDate.addingTimeInterval(311))
        XCTAssertEqual(recovered.sessions[0].seconds, 0)
        XCTAssertEqual(machine.current?.id, recovered.sessions[0].id)
    }

    func testIdleCutoffRemainsTheActualLastInputWhenItPrecedesCurrentSession() {
        var machine = ActivityTrackingMachine()

        _ = machine.update(
            app: safari,
            at: baseDate.addingTimeInterval(100),
            uptime: 100,
            idleSeconds: 250,
            blockers: [],
            enabled: true
        )
        let idle = machine.update(
            app: safari,
            at: baseDate.addingTimeInterval(300),
            uptime: 300,
            idleSeconds: 300,
            blockers: [],
            enabled: true
        )

        XCTAssertEqual(idle.sessions.count, 1)
        XCTAssertEqual(idle.sessions[0].endReason, .idle)
        XCTAssertEqual(idle.sessions[0].end, baseDate.addingTimeInterval(100))
        XCTAssertEqual(idle.sessions[0].seconds, 0)
        XCTAssertEqual(idle.truncateAfter, baseDate)
        XCTAssertNil(machine.current)
    }

    func testIdleCutoffIsReportedOncePerEpisodeWhileBlockedAndResetsAfterInput() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 0)
        _ = update(
            &machine,
            app: safari,
            seconds: 200,
            uptime: 200,
            idleSeconds: 100,
            blockers: [.locked]
        )

        let idle = update(
            &machine,
            app: safari,
            seconds: 400,
            uptime: 200,
            idleSeconds: 300,
            blockers: [.locked]
        )
        XCTAssertTrue(idle.sessions.isEmpty)
        XCTAssertEqual(idle.truncateAfter, baseDate.addingTimeInterval(100))

        let repeated = update(
            &machine,
            app: safari,
            seconds: 410,
            uptime: 200,
            idleSeconds: 310,
            blockers: [.locked]
        )
        XCTAssertTrue(repeated.sessions.isEmpty)
        XCTAssertNil(repeated.truncateAfter)

        let inputWhileBlocked = update(
            &machine,
            app: safari,
            seconds: 415,
            uptime: 200,
            idleSeconds: 1,
            blockers: [.locked]
        )
        XCTAssertTrue(inputWhileBlocked.sessions.isEmpty)
        XCTAssertNil(inputWhileBlocked.truncateAfter)

        let nextIdle = update(
            &machine,
            app: safari,
            seconds: 716,
            uptime: 200,
            idleSeconds: 301,
            blockers: [.locked]
        )
        XCTAssertTrue(nextIdle.sessions.isEmpty)
        XCTAssertEqual(nextIdle.truncateAfter, baseDate.addingTimeInterval(415))
    }

    func testWallClockJumpUsesOldWallTimeAndMonotonicDuration() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 0)
        _ = update(&machine, app: safari, seconds: 10, uptime: 10)

        let changed = update(&machine, app: safari, seconds: 10_010, uptime: 20)

        XCTAssertEqual(changed.sessions.count, 2)
        XCTAssertEqual(changed.sessions[0].endReason, .clockChanged)
        XCTAssertEqual(changed.sessions[0].end, baseDate.addingTimeInterval(20))
        XCTAssertEqual(changed.sessions[0].seconds, 20)

        XCTAssertEqual(changed.sessions[1].start, baseDate.addingTimeInterval(10_010))
        XCTAssertEqual(changed.sessions[1].seconds, 0)
        XCTAssertFalse(
            changed.sessions[0].start <= changed.sessions[1].end
                && changed.sessions[1].start < changed.sessions[0].end
        )
    }

    func testBackwardWallClockJumpNeverCreatesNegativeTimeOrOverlap() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 0)
        let changed = machine.update(
            app: safari,
            at: baseDate.addingTimeInterval(-50),
            uptime: 10,
            idleSeconds: 0,
            blockers: [],
            enabled: true
        )

        XCTAssertEqual(changed.sessions.count, 2)
        XCTAssertEqual(changed.sessions[0].endReason, .clockChanged)
        XCTAssertEqual(changed.sessions[0].end, baseDate.addingTimeInterval(10))
        XCTAssertEqual(changed.sessions[0].seconds, 10)
        XCTAssertEqual(changed.sessions[1].start, baseDate.addingTimeInterval(10))
        XCTAssertGreaterThanOrEqual(changed.sessions[1].end, changed.sessions[1].start)
        XCTAssertFalse(
            changed.sessions[0].start <= changed.sessions[1].end
                && changed.sessions[1].start < changed.sessions[0].end
        )
    }

    func testNilForegroundClosesSessionAsTerminated() {
        var machine = ActivityTrackingMachine()

        _ = update(&machine, app: safari, seconds: 0, uptime: 100)
        let terminated = update(&machine, app: nil, seconds: 10, uptime: 110)

        XCTAssertEqual(terminated.sessions.count, 1)
        XCTAssertEqual(terminated.sessions[0].endReason, .terminated)
        XCTAssertEqual(terminated.sessions[0].seconds, 10)
        XCTAssertNil(machine.current)
    }
}
