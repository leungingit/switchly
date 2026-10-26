//
//  GridHUDViewModel.swift
//  Switchly
//
//  State machine behind the gesture HUD.
//
//  The HUD is a *report*, not a controller: a swipe arrives already
//  recognised, the view model decides whether it maps to a desktop, and the
//  navigation service performs the switch. Every branch below is reachable
//  from a synthetic swipe + snapshot, so the states are unit tested rather
//  than only seen on a trackpad (docs/desktop-grid-design-spec.md §10).
//

import Foundation
import CoreGraphics
import ApplicationServices

/// What the HUD shows. Mirrors the state table in the design spec §10.
enum GridHUDPhase: Equatable {
    /// Current → target, switch in flight.
    case switching
    /// Four fingers resting: shows where the current desktop sits. Not a
    /// warning, and nothing switches.
    case locate
    /// The swipe points outside the 3×3 grid; the grid does not wrap.
    case edge
    /// A swipe landed inside the cooldown window; it was ignored.
    case coolingDown
    /// The target cell has no system desktop behind it.
    case notCreated
    /// Accessibility is missing, so the switch could not be completed.
    case accessibilityMissing
    /// The desktop list could not be read, so there is no current or target.
    case spacesUnavailable
    /// The switch was attempted and did not complete (hotkey missing, event
    /// post denied, activation failed).
    case failed

    /// Colour-coded as a warning state (the prototype's `.warn` pill).
    var isWarning: Bool {
        switch self {
        case .switching, .locate: return false
        default: return true
        }
    }
}

/// Result of feeding one swipe to the HUD.
enum GridHUDAction: Equatable {
    case none
    /// The caller should run the switch for this desktop.
    case navigate(Int)
}

@MainActor
final class GridHUDViewModel: ObservableObject {
    @Published private(set) var phase: GridHUDPhase?
    @Published private(set) var direction: SwipeDirection?
    @Published private(set) var targetNumber: Int?
    @Published private(set) var currentNumber: Int?
    @Published private(set) var createdNumbers: Set<Int> = []
    @Published private(set) var isVisible = false
    /// Grid position → real desktop number for the display being navigated,
    /// so swipes and the mini map follow the user's arrangement.
    @Published private(set) var layout: [Int] = DesktopGridLayout.identity
    @Published private(set) var language: AppLanguage
    @Published private(set) var material: CrystalMaterial
    /// Mirrors `AppSettings.enableBackgroundBlur`, so the HUD follows the same
    /// glass switch as every other panel instead of always drawing glass.
    @Published private(set) var enableGlass: Bool
    /// Mirrors `AppSettings.backgroundBlurOpacity`.
    @Published private(set) var glassOpacity: Double

    /// Auto-hide delays. The switch state hides itself when navigation
    /// returns; the warning states need a short dwell so the copy is readable.
    static let warningDwell: TimeInterval = 1.6
    /// With a rearranged grid the system slide can run against the finger
    /// direction, so the HUD stays a little after the switch to carry the
    /// "from → to" message instead of the animation.
    static let customLayoutDwell: TimeInterval = 0.9

    /// True while a finished switch keeps the HUD up for `customLayoutDwell`.
    private(set) var isLingering = false

    private let accessibilityStatus: () -> Bool
    private var lastSnapshot: DesktopSpaceSnapshot = .empty
    private var layouts: [String: [Int]]

    init(
        language: AppLanguage = .english,
        material: CrystalMaterial = .legacyDefault,
        enableGlass: Bool = true,
        glassOpacity: Double = 0.30,
        layouts: [String: [Int]] = [:],
        accessibilityStatus: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.language = language
        self.material = material
        self.enableGlass = enableGlass
        self.glassOpacity = glassOpacity
        self.layouts = layouts
        self.accessibilityStatus = accessibilityStatus
    }

    // MARK: - Input

    func applySettings(_ settings: AppSettings) {
        language = settings.language
        material = settings.crystalMaterial
        enableGlass = settings.enableBackgroundBlur
        glassOpacity = settings.backgroundBlurOpacity
        layouts = settings.gridLayouts
    }

    /// Feeds a recognised swipe. Returns the navigation the panel should run.
    func handle(swipe: TrackpadSwipeEvent, snapshot: DesktopSpaceSnapshot) -> GridHUDAction {
        lastSnapshot = snapshot
        isLingering = false
        layout = DesktopGridLayout.sanitized(layouts[DesktopGridLayout.key(for: snapshot.displayID)] ?? [])
        currentNumber = snapshot.currentDesktop?.number
        createdNumbers = Set(snapshot.desktops.map(\.number))
        direction = swipe.gesture.direction

        guard let current = currentNumber else {
            phase = .spacesUnavailable
            isVisible = true
            return .none
        }

        if swipe.suppressed {
            targetNumber = nil
            phase = .coolingDown
            isVisible = true
            return .none
        }

        guard let target = Self.target(from: current, direction: swipe.gesture.direction, layout: layout) else {
            targetNumber = nil
            phase = .edge
            isVisible = true
            return .none
        }

        targetNumber = target
        guard createdNumbers.contains(target) else {
            phase = .notCreated
            isVisible = true
            return .none
        }

        phase = .switching
        isVisible = true
        return .navigate(target)
    }

    /// Shows the mini map for a resting hand. Reads the same layout as a
    /// swipe, so the arrangement matches what the swipe would do.
    func showLocate(snapshot: DesktopSpaceSnapshot) {
        lastSnapshot = snapshot
        isLingering = false
        layout = DesktopGridLayout.sanitized(layouts[DesktopGridLayout.key(for: snapshot.displayID)] ?? [])
        currentNumber = snapshot.currentDesktop?.number
        createdNumbers = Set(snapshot.desktops.map(\.number))
        direction = nil
        targetNumber = nil
        phase = currentNumber == nil ? .spacesUnavailable : .locate
        isVisible = true
    }

    /// Called when the navigation service reports back.
    func finish(navigation result: DesktopNavigationResult) {
        switch result {
        case .switched:
            if layout != DesktopGridLayout.identity {
                isLingering = true
                return
            }
            isVisible = false
            phase = nil
            targetNumber = nil
            direction = nil
        case .notCreated:
            phase = .notCreated
        case .edge:
            phase = .edge
        case .failed(let reason):
            if !accessibilityStatus() {
                phase = .accessibilityMissing
            } else {
                AppLogger.warning("Desktop switch failed. reason=\(reason)")
                phase = .failed
            }
        }
    }

    /// Edge / cooldown / not-created / failure states dwell briefly, then hide.
    var autoDismissDelay: TimeInterval? {
        if isLingering { return Self.customLayoutDwell }
        guard let phase, phase != .switching, phase != .locate else { return nil }
        return Self.warningDwell
    }

    func dismiss() {
        isLingering = false
        isVisible = false
        phase = nil
        direction = nil
        targetNumber = nil
    }

    // MARK: - Mapping

    /// Neighbouring desktop for a swipe, or nil at the grid edge. Neighbours
    /// are taken from grid positions, so a rearranged grid swipes as shown.
    static func target(
        from current: Int,
        direction: SwipeDirection,
        layout: [Int] = DesktopGridLayout.identity
    ) -> Int? {
        let layout = DesktopGridLayout.sanitized(layout)
        guard let position = layout.firstIndex(of: current) else { return nil }
        let column = position % 3 + direction.columnDelta
        let row = position / 3 + direction.rowDelta
        guard (0..<3).contains(column), (0..<3).contains(row) else { return nil }
        return layout[row * 3 + column]
    }

    // MARK: - Copy

    var title: String {
        guard let phase else { return "" }
        switch phase {
        case .locate:
            return String(format: t("You are on Desktop %d"), currentNumber ?? 1)
        case .switching:
            return String(format: t("Switching to Desktop %d…"), targetNumber ?? currentNumber ?? 1)
        case .edge:
            return t("At the edge")
        case .coolingDown:
            return t("Cooling down")
        case .notCreated:
            return String(format: t("Desktop %d not created"), targetNumber ?? 1)
        case .accessibilityMissing:
            return t("Accessibility permission required")
        case .spacesUnavailable:
            return t("Desktop information is unavailable")
        case .failed:
            return t("Could not switch desktop")
        }
    }

    var subtitle: String {
        guard let phase else { return "" }
        switch phase {
        case .locate:
            return t("Lift your fingers to dismiss")
        case .switching:
            return t("Dismisses when the system switch finishes")
        case .edge:
            return t("No more desktops (does not wrap)")
        case .coolingDown:
            return t("Rapid swipes are ignored for a moment")
        case .notCreated:
            return t("Create it in Mission Control first")
        case .accessibilityMissing:
            return t("Grant Accessibility in System Settings to switch desktops")
        case .spacesUnavailable:
            return t("Switchly could not read the system desktops. Nothing was changed.")
        case .failed:
            return t("Use ⌃1–9 or the menu to switch")
        }
    }

    /// "Desktop 5 → 9" or, for the warning states, just the state title.
    var headline: String {
        guard phase == .switching,
              let current = currentNumber,
              let target = targetNumber else {
            return title
        }
        return String(format: t("Desktop %d → %d"), current, target)
    }

    /// Gesture plus keyboard path, per D60-C.
    var gestureHint: String? {
        guard phase == .switching,
              let direction,
              let target = targetNumber else {
            return nil
        }
        return String(format: t("Four-finger swipe %@"), direction.displayName(language: language))
            + " · "
            + String(format: t("or press ⌃%d"), target)
    }

    /// Only a live switch shows the swipe arrow; the warning states show their
    /// own glyph so a direction never implies a switch that will not happen.
    var arrowSymbol: String {
        guard phase == .switching, let direction else { return "" }
        switch direction {
        case .right: return "arrow.right"
        case .upRight: return "arrow.up.right"
        case .up: return "arrow.up"
        case .upLeft: return "arrow.up.left"
        case .left: return "arrow.left"
        case .downLeft: return "arrow.down.left"
        case .down: return "arrow.down"
        case .downRight: return "arrow.down.right"
        }
    }

    func isHighlighted(_ direction: SwipeDirection) -> Bool {
        phase == .switching && self.direction == direction
    }

    func miniState(for number: Int) -> GridHUDMiniState {
        if number == currentNumber { return .current }
        if phase == .switching, number == targetNumber { return .target }
        if !createdNumbers.isEmpty, !createdNumbers.contains(number) { return .missing }
        return .plain
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}

/// Cell rendering inside the HUD's 3×3 mini map.
enum GridHUDMiniState: Equatable {
    case plain
    case current
    case target
    case missing
}
