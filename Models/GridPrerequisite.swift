//
//  GridPrerequisite.swift
//  Switchly
//
//  Read-only prerequisite state for the desktop grid.
//
//  The settings section and the onboarding window render the same snapshot
//  (docs/desktop-grid-tasks.md T17, T18, T20). Nothing here writes a system
//  preference: the ⌃1–9 shortcuts are
//  *read* so the UI can tell the user what to change by hand (T14, R3).
//

import Foundation

/// One prerequisite and what the app could learn about it.
enum GridPrerequisiteState: Equatable {
    /// The app verified the condition.
    case met
    /// The app verified the condition is missing.
    case unmet
    /// macOS does not expose this to apps (or the private framework is
    /// unavailable), so the user has to check it in System Settings.
    case undetectable

    /// Status label key. Always paired with the state's colour so the state is
    /// never encoded by colour alone (design spec §11).
    var statusKey: String {
        switch self {
        case .met: return "Done"
        case .unmet: return "Not done"
        case .undetectable: return "Can’t check"
        }
    }

    func statusText(language: AppLanguage) -> String {
        language.localizedString(statusKey)
    }
}

enum GridPrerequisite: String, CaseIterable, Equatable {
    case accessibility
    case screenRecording
    case twoDesktops
    case desktopHotKeys
    case gestureAvailability

    func title(language: AppLanguage) -> String {
        language.localizedString(titleKey)
    }

    func detail(language: AppLanguage) -> String {
        language.localizedString(detailKey)
    }

    var titleKey: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .twoDesktops: return "At least two desktops"
        case .desktopHotKeys: return "⌃1–9 desktop shortcuts"
        case .gestureAvailability: return "Trackpad gesture capture"
        }
    }

    var detailKey: String {
        switch self {
        case .accessibility:
            return "Needed to read window names and to switch desktops reliably."
        case .screenRecording:
            return "Only affects desktop previews. Gestures work without it."
        case .twoDesktops:
            return "macOS creates desktops; add them in Mission Control."
        case .desktopHotKeys:
            return "Switchly uses the system “Switch to Desktop” shortcuts for empty desktops. Enable them in System Settings › Keyboard."
        case .gestureAvailability:
            return "Switchly could not read raw trackpad contacts on this Mac. ⌃1–9 and the menu still work."
        }
    }

    /// Whether the state blocks gestures (as opposed to only degrading them).
    var blocksGestures: Bool {
        switch self {
        case .screenRecording, .desktopHotKeys: return false
        default: return true
        }
    }

    /// The System Settings pane (or Mission Control) that fixes this item.
    /// Nil when the app cannot point anywhere useful.
    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .twoDesktops:
            return nil
        case .desktopHotKeys:
            return URL(string: Self.usesModernSettingsPanes
                ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                : "x-apple.systempreferences:com.apple.preference.keyboard")
        case .gestureAvailability:
            return nil
        }
    }

    /// Desktops are created in Mission Control, which is an app, not a pane.
    var opensMissionControl: Bool { self == .twoDesktops }

    var hasAction: Bool { opensMissionControl || settingsURL != nil }

    /// System Settings moved to per-pane extensions in macOS 13 (Ventura).
    private static var usesModernSettingsPanes: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        )
    }

    /// Shared soft copy for a state the app could not verify (D61-D).
    static let undetectableDetailKey =
        "macOS doesn’t let Switchly read this setting. Please confirm it in System Settings."

    /// What to say when the state is `.undetectable`. Gesture capture has its
    /// own explanation (the Mac cannot be read at all); everything else uses
    /// the shared soft copy instead of pretending the check passed.
    func undetectableDetail(language: AppLanguage) -> String {
        switch self {
        case .gestureAvailability:
            return detail(language: language)
        default:
            return language.localizedString(Self.undetectableDetailKey)
        }
    }
}

/// Snapshot of every prerequisite, with the gesture-relevant ones first.
struct GridPrerequisiteSnapshot: Equatable {
    var states: [GridPrerequisite: GridPrerequisiteState]

    static let empty = GridPrerequisiteSnapshot(states: [:])

    func state(of prerequisite: GridPrerequisite) -> GridPrerequisiteState {
        states[prerequisite] ?? .undetectable
    }

    var totalCount: Int { GridPrerequisite.allCases.count }

    var metCount: Int {
        GridPrerequisite.allCases.filter { state(of: $0) == .met }.count
    }

    /// True when a prerequisite that blocks gestures is verified missing.
    /// An unverifiable item does not block: the app has no evidence either way.
    var gesturesBlocked: Bool {
        GridPrerequisite.allCases.contains { prerequisite in
            prerequisite.blocksGestures && state(of: prerequisite) == .unmet
        }
    }

    /// The items the user still has to act on, in display order.
    var unmetItems: [GridPrerequisite] {
        GridPrerequisite.allCases.filter { state(of: $0) != .met }
    }

    /// "4 of 5 met" — the settings summary and the onboarding header share it.
    func summary(language: AppLanguage) -> String {
        String(format: language.localizedString("%d of %d met"), metCount, totalCount)
    }
}
