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
    private let interceptor: SystemGestureIntercepting
    private var settingsCancellable: AnyCancellable?
    private var isNavigating = false

    /// Set while a switch is in flight so a second gesture cannot stack.
    private(set) var isEnabled = false

    /// Called after every settings application with the resulting listener
    /// state, so the overview and the HUD follow the same switch the listener
    /// does (T17, R10). The AppDelegate wires it to the panels; tests leave it
    /// nil, which is why the coordinator never touches AppKit windows itself.
    var onListenerStateChanged: ((Bool) -> Void)?

    /// Five-finger swipe down. AppDelegate opens the overview panel.
    var onOverviewRequested: (() -> Void)?
    private var overviewGestureEnabled = true
    private var naturalSwipeDirection = true
    private var interceptSystemGestures = true

    /// Five-finger swipe up while the system gestures are taken over.
    var onMissionControlRequested: (() -> Void)?

    init(
        gestureService: TrackpadGestureServiceProtocol = TrackpadGestureService.shared,
        navigation: DesktopNavigationServiceProtocol = DesktopNavigationService.shared,
        spaceService: DesktopSpaceServiceProtocol = DesktopSpaceService.shared,
        prerequisites: GridPrerequisiteServiceProtocol = GridPrerequisiteService(),
        interceptor: SystemGestureIntercepting = SystemGestureInterceptor.shared
    ) {
        self.interceptor = interceptor
        self.gestureService = gestureService
        self.navigation = navigation
        self.spaceService = spaceService
        self.prerequisites = prerequisites
    }

    // MARK: - Lifecycle

    /// Applies the master switch. Safe to call repeatedly and on every
    /// settings change; starting an already-running listener is a no-op.
    func apply(settings: AppSettings) {
        overviewGestureEnabled = settings.gridOverviewGestureEnabled
        naturalSwipeDirection = settings.gridNaturalSwipeDirection
        interceptSystemGestures = settings.gridInterceptSystemGestures
        guard settings.gridEnabled else {
            stop()
            return
        }
        start()
        if isEnabled && interceptSystemGestures {
            interceptor.start()
        } else {
            interceptor.stop()
        }
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
        if system.conflictsWithGrid && !interceptSystemGestures {
            // Not fatal: the system gesture and ours fire together. The user
            // has to turn the system one off by hand; nothing is written here.
            AppLogger.warning(
                "System four-finger swipe conflicts with the grid. horizontal=\(system.horizontalSwipeEnabled), vertical=\(system.verticalSwipeEnabled), action=user_must_disable"
            )
        }
    }

    func stop() {
        guard isEnabled else {
            interceptor.stop()
            gestureService.onSwipe = nil
            return
        }
        interceptor.stop()
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
        if swipe.gesture.fingers >= SwipeDefaults.overviewFingers {
            // Only the overview recogniser fires with five fingers.
            guard isEnabled, !swipe.suppressed else { return }
            switch swipe.gesture.direction {
            case .down where overviewGestureEnabled:
                AppLogger.info("Desktop grid overview requested. source=five_finger_swipe")
                onOverviewRequested?()
            case .up where interceptor.isIntercepting:
                // The system's four-finger up is swallowed; this replaces it
                // so a desktop can still be added in Mission Control.
                AppLogger.info("Mission Control requested. source=five_finger_swipe")
                onMissionControlRequested?()
            default:
                break
            }
            return
        }
        guard isEnabled, !isNavigating else {
            AppLogger.debug("Trackpad swipe ignored. reason=not_ready")
            return
        }
        // Natural: fingers left moves to the desktop on the right.
        let swipe = naturalSwipeDirection ? swipe.reversed : swipe

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Layout only: with no window list the target has no windows, so
            // navigation takes the ⌃N path, which moves at once.
            let snapshot = await self.spaceService.loadLayout()
            guard self.isEnabled else { return }
            // Two frames can land in the same runloop turn; only the first
            // one may open a navigation.
            guard !self.isNavigating else { return }
            // The display in use has no second desktop: stay silent rather
            // than prompting to create one.
            guard snapshot.desktops.count >= 2 else {
                AppLogger.debug("Trackpad swipe ignored. reason=single_desktop_display")
                return
            }

            let action = GridHUDPanel.shared.present(swipe: swipe, snapshot: snapshot)
            guard case .navigate(let number) = action else { return }

            self.isNavigating = true
            var result = await self.navigation.navigate(to: number, snapshot: snapshot)
            if case .failed(reason: "hotkey_not_configured") = result {
                // No ⌃N binding: the slower app-activation path needs windows.
                result = await self.navigation.navigate(to: number, snapshot: await self.spaceService.loadSnapshot())
            }
            self.isNavigating = false
            GridHUDPanel.shared.finish(navigation: result)
        }
    }
}
