//
//  GridPrerequisiteTests.swift
//  SwitchlyTests
//
//  The prerequisite model is the single source of truth for the settings tab,
//  the onboarding window and the gesture gate (T20). These tests pin the
//  combination rules and the wording contract; nothing touches a real system
//  preference.
//

import XCTest
@testable import Switchly

final class GridPrerequisiteTests: XCTestCase {

    private func snapshot(_ states: [GridPrerequisite: GridPrerequisiteState]) -> GridPrerequisiteSnapshot {
        GridPrerequisiteSnapshot(states: states)
    }

    private func allMet() -> GridPrerequisiteSnapshot {
        var states: [GridPrerequisite: GridPrerequisiteState] = [:]
        for item in GridPrerequisite.allCases { states[item] = .met }
        return snapshot(states)
    }

    // MARK: - Counting

    func testEveryPrerequisiteIsAccountedForInTheSummary() {
        let met = allMet()
        XCTAssertEqual(met.metCount, GridPrerequisite.allCases.count)
        XCTAssertEqual(met.totalCount, 7)
        XCTAssertFalse(met.gesturesBlocked)
        XCTAssertEqual(
            met.summary(language: .english),
            "7 of 7 met"
        )
        XCTAssertEqual(
            met.summary(language: .simplifiedChinese),
            "已满足 7 / 7 项"
        )
    }

    func testMissingItemsAreReportedInDisplayOrder() {
        var states: [GridPrerequisite: GridPrerequisiteState] = [:]
        for item in GridPrerequisite.allCases { states[item] = .met }
        states[.accessibility] = .unmet
        states[.systemFourFingerVerticalSwipe] = .unmet
        let result = snapshot(states)

        XCTAssertEqual(result.metCount, 5)
        XCTAssertEqual(result.unmetItems, [.accessibility, .systemFourFingerVerticalSwipe])
        XCTAssertTrue(result.gesturesBlocked)
        XCTAssertEqual(result.summary(language: .english), "5 of 7 met")
    }

    /// An item the app cannot read is not evidence of a missing condition:
    /// it must not block gestures, but it must still count as "not met".
    func testUndetectableItemDoesNotBlockGesturesButIsNotCountedAsMet() {
        var states: [GridPrerequisite: GridPrerequisiteState] = [:]
        for item in GridPrerequisite.allCases { states[item] = .met }
        states[.gestureAvailability] = .undetectable
        let result = snapshot(states)

        XCTAssertFalse(result.gesturesBlocked)
        XCTAssertEqual(result.metCount, 6)
        XCTAssertTrue(result.unmetItems.contains(.gestureAvailability))
    }

    func testEmptySnapshotTreatsEverythingAsUndetectable() {
        let empty = GridPrerequisiteSnapshot.empty
        XCTAssertEqual(empty.metCount, 0)
        XCTAssertFalse(empty.gesturesBlocked, "no evidence is not a confirmed failure")
        XCTAssertEqual(empty.unmetItems.count, GridPrerequisite.allCases.count)
    }

    // MARK: - Semantics

    func testOnlyTheSystemGestureSwitchesAreInverted() {
        let inverted = GridPrerequisite.allCases.filter(\.isInverted)
        XCTAssertEqual(inverted, [.systemFourFingerHorizontalSwipe, .systemFourFingerVerticalSwipe])
    }

    func testScreenRecordingAndShortcutsOnlyDegradeTheExperience() {
        XCTAssertFalse(GridPrerequisite.screenRecording.blocksGestures)
        XCTAssertFalse(GridPrerequisite.desktopHotKeys.blocksGestures)
        for item in GridPrerequisite.allCases
        where item != .screenRecording && item != .desktopHotKeys {
            XCTAssertTrue(item.blocksGestures, "\(item) must block gestures")
        }
    }

    func testStatusCopyExistsInBothLanguagesAndDiffersByState() {
        let english = Set(GridPrerequisiteState.allCasesForTesting.map { $0.statusText(language: .english) })
        let chinese = Set(GridPrerequisiteState.allCasesForTesting.map { $0.statusText(language: .simplifiedChinese) })
        XCTAssertEqual(english.count, 3, "each state needs its own label")
        XCTAssertEqual(chinese.count, 3)
        XCTAssertTrue(chinese.contains("无法自动检测"))
    }

    func testUndetectableDetailUsesTheSoftCopyExceptForGestureCapture() {
        XCTAssertEqual(
            GridPrerequisite.accessibility.undetectableDetail(language: .english),
            GridPrerequisite.undetectableDetailKey
        )
        XCTAssertEqual(
            GridPrerequisite.gestureAvailability.undetectableDetail(language: .english),
            GridPrerequisite.gestureAvailability.detail(language: .english)
        )
    }

    func testSystemSettingsDeepLinksMatchTheItem() {
        XCTAssertEqual(
            GridPrerequisite.accessibility.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            GridPrerequisite.screenRecording.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        // Desktops are created in Mission Control, which is an app not a pane.
        XCTAssertNil(GridPrerequisite.twoDesktops.settingsURL)
        XCTAssertTrue(GridPrerequisite.twoDesktops.opensMissionControl)
        XCTAssertTrue(GridPrerequisite.twoDesktops.hasAction)
        // Gesture capture cannot be fixed in System Settings.
        XCTAssertNil(GridPrerequisite.gestureAvailability.settingsURL)
        XCTAssertFalse(GridPrerequisite.gestureAvailability.hasAction)
        for item in GridPrerequisite.allCases where item != .twoDesktops && item != .gestureAvailability {
            XCTAssertNotNil(item.settingsURL, "\(item) needs a System Settings link")
        }
    }

    func testTitlesAndDetailsAreLocalisedAndNonEmpty() {
        for item in GridPrerequisite.allCases {
            let english = item.title(language: .english)
            let chinese = item.title(language: .simplifiedChinese)
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(chinese.isEmpty)
            // English copy legitimately equals its key for a few short labels,
            // so only the Chinese value is checked for a real translation.
            XCTAssertNotEqual(chinese, item.titleKey, "missing zh copy for \(item.titleKey)")
            XCTAssertNotEqual(
                item.detail(language: .simplifiedChinese),
                item.detailKey,
                "missing zh detail for \(item.detailKey)"
            )
        }
    }
}

private extension GridPrerequisiteState {
    /// `CaseIterable` is not on the production enum (it is a payload-free
    /// state, not a settings axis); the test lists the cases explicitly so a
    /// new state cannot be added without updating the copy contract.
    static var allCasesForTesting: [GridPrerequisiteState] { [.met, .unmet, .undetectable] }
}
