//
//  DesktopGridCoordinator.swift
//  Switchly
//
//  Owns the gesture listener's lifecycle and wires the four stage-4 pieces
//  together: trackpad frames → recogniser → HUD → navigation → HUD result.
//
//  It is the only place that decides *when* the listener runs, so the rule
//  "listen only while the desktop grid is enabled" has one home
//  (docs/desktop-grid-tasks.md T12, T16).
//

import Foundation
import AppKit
import Combine

@MainActor
final class DesktopGridCoordinator {
    static let shared = DesktopGridCoordinator()

    private let gestureService: TrackpadGestureServiceProtocol
    private let navigation: DesktopNavigationServiceProtocol
    private let spaceService: DesktopSpaceServiceProtocol
    private let prerequisites: GridPrerequisiteServiceProtocol
    private var settingsCancellable: AnyCancellable?
    private var isNavigating = false

    /// Set while a switch is in flight so a second gesture cannot stack.
    private(set) var isEnabled = false

    /// Called after every settings application with the resulting listener
    /// state, so the overview and the HUD follow the same switch the listener
    /// does (T17, R10). The AppDelegate wires it to the panels; tests leave it
    /// nil, which is why the coordinator never touches AppKit windows itself.
    var onListenerStateChanged: ((Bool) -> Void)?

    init(
        gestureService: TrackpadGestureServiceProtocol = TrackpadGestureService.shared,
        navigation: DesktopNavigationServiceProtocol = DesktopNavigationService.shared,
        spaceService: DesktopSpaceServiceProtocol = DesktopSpaceService.shared,
        prerequisites: GridPrerequisiteServiceProtocol = GridPrerequisiteService()
    ) {
        self.gestureService = gestureService
        self.navigation = navigation
        self.spaceService = spaceService
        self.prerequisites = prerequisites
    }

    // MARK: - Lifecycle

    /// Applies the master switch. Safe to call repeatedly and on every
    /// settings change; starting an already-running listener is a no-op.
    func apply(settings: AppSettings) {
        guard settings.gridEnabled else {
            stop()
            return
        }
        start()
    }

    func start() {
        guard !isEnabled else { return }

        gestureService.onSwipe = { [weak self] swipe in
            self?.handle(swipe: swipe)
        }

        guard gestureService.start() else {
            // The design spec keeps the HUD off screen when the framework is
            // missing (§10), so this is a log line plus the menu/⌃1–9 fallback
            // rather than a panel the user cannot act on. `isEnabled` stays
            // false, so a later settings change retries the start.
            gestureService.onSwipe = nil
            AppLogger.warning("Desktop grid gestures unavailable. fallingBack=menu,shortcut")
            onListenerStateChanged?(false)
            return
        }

        isEnabled = true
        onListenerStateChanged?(true)

        let system = gestureService.systemGestureState()
        if system.conflictsWithGrid {
            // Not fatal: the system gesture and ours fire together. The user
            // has to turn the system one off by hand; nothing is written here.
            AppLogger.warning(
                "System four-finger swipe conflicts with the grid. horizontal=\(system.horizontalSwipeEnabled), vertical=\(system.verticalSwipeEnabled), action=user_must_disable"
            )
        }
    }

    func stop() {
        guard isEnabled else {
            gestureService.onSwipe = nil
            return
        }
        gestureService.stop()
        gestureService.onSwipe = nil
        isEnabled = false
        onListenerStateChanged?(false)
        AppLogger.info("Desktop grid gestures stopped")
    }

    /// The panel routes its own switches (click, Return, ⌃1–9) through here so
    /// the overview and the gesture path share one implementation (T15).
    @discardableResult
    func switchToDesktop(number: Int) async -> DesktopNavigationResult {
        guard !isNavigating else {
            AppLogger.debug("Desktop switch ignored. reason=switch_in_flight, target=\(number)")
            return .failed(reason: "switch_in_flight")
        }
        isNavigating = true
        defer { isNavigating = false }
        let snapshot = await spaceService.loadSnapshot()
        return await navigation.navigate(to: number, snapshot: snapshot)
    }

    func prerequisiteSnapshot(spaceCount: Int) -> GridPrerequisiteSnapshot {
        prerequisites.snapshot(spaceCount: spaceCount)
    }

    // MARK: - Swipe handling

    private func handle(swipe: TrackpadSwipeEvent) {
        guard isEnabled, !isNavigating else {
            AppLogger.debug("Trackpad swipe ignored. reason=not_ready")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.spaceService.loadSnapshot()
            guard self.isEnabled else { return }
            // Two frames can land in the same runloop turn; only the first
            // one may open a navigation.
            guard !self.isNavigating else { return }

            let action = GridHUDPanel.shared.present(swipe: swipe, snapshot: snapshot)
            guard case .navigate(let number) = action else { return }

            self.isNavigating = true
            let result = await self.navigation.navigate(to: number, snapshot: snapshot)
            self.isNavigating = false
            GridHUDPanel.shared.finish(navigation: result)
        }
    }
}
