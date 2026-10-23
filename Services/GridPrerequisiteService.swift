//
//  GridPrerequisiteService.swift
//  Switchly
//
//  Assembles the read-only prerequisite snapshot for the desktop grid.
//
//  This is the single source of truth for "what is missing" (T20): the
//  settings section, the onboarding window and the gesture coordinator all
//  read the same snapshot instead of re-implementing the checks. Nothing here
//  writes a system preference.
//

import Foundation
import AppKit

protocol GridPrerequisiteServiceProtocol {
    func snapshot(spaceCount: Int) -> GridPrerequisiteSnapshot
}

final class GridPrerequisiteService: GridPrerequisiteServiceProtocol {
    private let accessibilityStatus: () -> Bool
    private let screenRecordingStatus: () -> Bool
    private let gestureService: TrackpadGestureServiceProtocol
    private let hotKeyReader: DesktopHotKeyReading

    init(
        accessibilityStatus: @escaping () -> Bool = { AXIsProcessTrusted() },
        screenRecordingStatus: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        gestureService: TrackpadGestureServiceProtocol = TrackpadGestureService.shared,
        hotKeyReader: DesktopHotKeyReading = SystemDesktopHotKeyReader()
    ) {
        self.accessibilityStatus = accessibilityStatus
        self.screenRecordingStatus = screenRecordingStatus
        self.gestureService = gestureService
        self.hotKeyReader = hotKeyReader
    }

    func snapshot(spaceCount: Int) -> GridPrerequisiteSnapshot {
        let systemGestures = gestureService.systemGestureState()

        let states: [GridPrerequisite: GridPrerequisiteState] = [
            .accessibility: accessibilityStatus() ? .met : .unmet,
            .screenRecording: screenRecordingStatus() ? .met : .unmet,
            .twoDesktops: spaceCount >= 2 ? .met : .unmet,
            // Empty desktops are switched with the system "Switch to Desktop
            // N" hotkey, so at least one enabled binding is required for the
            // keyboard path to exist at all.
            .desktopHotKeys: hotKeyReader.readBindings().isAvailable ? .met : .unmet,
            // These two are inverted: "met" means the system gesture is off,
            // because the app cannot intercept it (evaluation §11.2).
            .systemFourFingerHorizontalSwipe: systemGestures.horizontalSwipeEnabled ? .unmet : .met,
            .systemFourFingerVerticalSwipe: systemGestures.verticalSwipeEnabled ? .unmet : .met,
            .gestureAvailability: gestureService.isAvailable ? .met : .unmet,
        ]

        return GridPrerequisiteSnapshot(states: states)
    }
}
