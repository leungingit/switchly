//
//  GridPrerequisiteViewModelTests.swift
//  SwitchlyTests
//
//  The shared prerequisite view model (T17, T18, T20) and its resource
//  lifetime (T23): repeated open/close must not stack NotificationCenter
//  observers, and the snapshot must come from the injected service.
//

import XCTest
import AppKit
@testable import Switchly

private final class FixedPrerequisiteService: GridPrerequisiteServiceProtocol {
    var snapshotValue: GridPrerequisiteSnapshot
    private(set) var calls: [Int] = []

    init(snapshot: GridPrerequisiteSnapshot) {
        self.snapshotValue = snapshot
    }

    func snapshot(spaceCount: Int) -> GridPrerequisiteSnapshot {
        calls.append(spaceCount)
        return snapshotValue
    }
}

private final class StubSpaceService: DesktopSpaceServiceProtocol {
    var snapshot: DesktopSpaceSnapshot
    private(set) var loadCount = 0

    init(count: Int) {
        snapshot = DesktopSpaceSnapshot(
            desktops: (1...max(1, count)).map { number in
                Desktop(id: UInt64(number), number: number, isCurrent: number == 1, windows: [])
            },
            availability: .available,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func loadSnapshot() async -> DesktopSpaceSnapshot {
        loadCount += 1
        return snapshot
    }
}

@MainActor
final class GridPrerequisiteViewModelTests: XCTestCase {

    private func allMetSnapshot() -> GridPrerequisiteSnapshot {
        var states: [GridPrerequisite: GridPrerequisiteState] = [:]
        for item in GridPrerequisite.allCases { states[item] = .met }
        return GridPrerequisiteSnapshot(states: states)
    }

    private func makeModel(
        service: GridPrerequisiteServiceProtocol,
        spaces: DesktopSpaceServiceProtocol,
        language: AppLanguage = .english
    ) -> GridPrerequisiteViewModel {
        GridPrerequisiteViewModel(service: service, spaceService: spaces, language: language)
    }

    func testRefreshReadsTheServiceOnceWithTheDesktopCount() async {
        let service = FixedPrerequisiteService(snapshot: allMetSnapshot())
        let spaces = StubSpaceService(count: 3)
        let model = makeModel(service: service, spaces: spaces)

        await model.refresh()

        XCTAssertEqual(service.calls, [3])
        XCTAssertEqual(model.spaceCount, 3)
        XCTAssertEqual(model.snapshot.metCount, 7)
        XCTAssertFalse(model.isRefreshing)
    }

    /// The settings tab and the onboarding window share one service; neither
    /// may invent its own count.
    func testSummaryComesFromTheSnapshotNotFromTheView() async {
        var states: [GridPrerequisite: GridPrerequisiteState] = [:]
        for item in GridPrerequisite.allCases { states[item] = .met }
        states[.accessibility] = .unmet
        let service = FixedPrerequisiteService(
            snapshot: GridPrerequisiteSnapshot(states: states)
        )
        let model = makeModel(service: service, spaces: StubSpaceService(count: 2))

        await model.refresh()

        XCTAssertEqual(model.snapshot.summary(language: .english), "6 of 7 met")
    }

    func testRepeatedStartAndStopNeverStacksObservers() {
        let model = makeModel(
            service: FixedPrerequisiteService(snapshot: allMetSnapshot()),
            spaces: StubSpaceService(count: 2)
        )

        XCTAssertEqual(model.observerCount, 0)

        model.startObserving()
        model.startObserving()
        model.startObserving()
        XCTAssertEqual(model.observerCount, 1, "a second show must not register again")

        model.stopObserving()
        XCTAssertEqual(model.observerCount, 0)

        // Ten open/close cycles leave exactly one registration while open and
        // none after closing — no growth across a long session.
        for _ in 0..<10 {
            model.startObserving()
            model.stopObserving()
        }
        XCTAssertEqual(model.observerCount, 0)
        model.startObserving()
        XCTAssertEqual(model.observerCount, 1)
        model.stopObserving()
    }

    func testStoppingWithoutStartingIsSafe() {
        let model = makeModel(
            service: FixedPrerequisiteService(snapshot: allMetSnapshot()),
            spaces: StubSpaceService(count: 2)
        )
        model.stopObserving()
        model.stopObserving()
        XCTAssertEqual(model.observerCount, 0)
    }

    func testApplyingSettingsUpdatesTheLanguage() async {
        let model = makeModel(
            service: FixedPrerequisiteService(snapshot: allMetSnapshot()),
            spaces: StubSpaceService(count: 2)
        )
        var settings = AppSettings.default
        settings.language = .simplifiedChinese
        model.applySettings(settings)

        await model.refresh()
        XCTAssertEqual(model.snapshot.summary(language: model.language), "已满足 7 / 7 项")
    }

    func testRefreshSoonRunsTheServiceAsynchronously() async {
        let service = FixedPrerequisiteService(snapshot: allMetSnapshot())
        let model = makeModel(service: service, spaces: StubSpaceService(count: 4))

        model.refreshSoon()
        // Let the queued task run; the assertion is about the call, not timing.
        for _ in 0..<50 where service.calls.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(service.calls, [4])
    }
}
