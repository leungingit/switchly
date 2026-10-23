//
//  DesktopNavigationService.swift
//  Switchly
//
//  Turns a target desktop into an actual Space switch.
//
//  Two paths only, both verified in
//  docs/desktop-grid-evaluation-2026-10-21.md §10.2:
//  1. desktop has windows → activate one of its apps (B1, 0.63–0.73 s);
//  2. desktop is empty → post the system "switch to desktop N" hotkey (D,
//     0.75 s), whose real key binding is read from com.apple.symbolichotkeys.
//
//  Never uses bridged SetCurrentSpace: the evaluation (§9.3) proved it only
//  changes the management value and leaves the composited screen behind.
//

import Foundation
import AppKit
import CoreGraphics

/// How a switch was carried out; logged, never shown as raw copy.
enum DesktopSwitchPath: String, Equatable {
    case applicationActivation = "app_activation"
    case systemHotKey = "system_hotkey"
    case unavailable = "unavailable"
}

/// One "switch to desktop N" system hotkey, as the user configured it.
struct DesktopHotKeyBinding: Equatable {
    /// Virtual key code.
    let keyCode: UInt16
    /// NSEvent modifier flags as stored by `symbolichotkeys`
    /// (control = 262144, option = 524288, shift = 131072, command = 1048576).
    let modifiers: UInt32
}

/// The nine bindings, indexed by desktop number (1…9).
struct DesktopHotKeyBindings: Equatable {
    /// A number is present only when its hotkey is enabled and well formed.
    var bindings: [Int: DesktopHotKeyBinding]

    static let empty = DesktopHotKeyBindings(bindings: [:])

    subscript(number: Int) -> DesktopHotKeyBinding? { bindings[number] }

    var isAvailable: Bool { !bindings.isEmpty }
}

enum DesktopNavigationResult: Equatable {
    case switched(number: Int, path: DesktopSwitchPath, confirmed: Bool)
    case notCreated(number: Int)
    case edge
    case failed(reason: String)

    var didSwitch: Bool {
        if case .switched = self { return true }
        return false
    }
}

/// Injection seams so the navigation state machine is testable without
/// Spaces, Accessibility or synthetic events.
protocol DesktopSwitching {
    func activateApplication(pid: pid_t) async throws
    /// Posts the system hotkey. Returns false when the event could not be
    /// posted (missing post-event permission).
    func postSystemHotKey(_ binding: DesktopHotKeyBinding) -> Bool
}

final class SystemDesktopSwitcher: DesktopSwitching {
    private let windowSwitch: WindowSwitchServiceProtocol

    init(windowSwitch: WindowSwitchServiceProtocol = WindowSwitchService.shared) {
        self.windowSwitch = windowSwitch
    }

    func activateApplication(pid: pid_t) async throws {
        try await windowSwitch.switchToApplication(pid: pid)
    }

    /// Posts the system hotkey through the session event tap. `CGEvent.post`
    /// needs the same permission class the evaluation used for path D.
    func postSystemHotKey(_ binding: DesktopHotKeyBinding) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: binding.keyCode, keyDown: false) else {
            return false
        }
        let flags = Self.flags(fromHotKeyModifiers: binding.modifiers)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// `symbolichotkeys` stores NSEvent modifier flags (control = 1 << 18),
    /// not Carbon modifiers — the evaluation's Control+digit entry is 262144.
    static func flags(fromHotKeyModifiers mask: UInt32) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(mask & 0x00FF0000))
    }
}

/// Reads `com.apple.symbolichotkeys` 118–126. Read-only: the evaluation
/// restored the user's plist and nothing here writes it (R7).
protocol DesktopHotKeyReading {
    func readBindings() -> DesktopHotKeyBindings
}

final class SystemDesktopHotKeyReader: DesktopHotKeyReading {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    /// Carbon IDs for "Switch to Desktop 1…9".
    static let firstHotKeyID = 118
    static let lastHotKeyID = 126

    /// ANSI key codes for 1…9 and the control modifier, i.e. the system's
    /// default "Switch to Desktop N" binding (⌃N).
    static let defaultKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    static let controlModifier: UInt32 = 262144

    func readBindings() -> DesktopHotKeyBindings {
        let stored = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            Self.domain
        ) as? [String: Any]
        return Self.bindings(from: stored ?? [:])
    }

    /// macOS only writes an entry after the user edits it; an absent entry
    /// means the system default ⌃N, which System Settings shows as enabled
    /// (measured on macOS 27: 118–121 absent while "Switch to Desktop 1–4"
    /// were on). An entry that exists but is disabled stays disabled. The
    /// switch confirmer still verifies every jump, so a wrong default can
    /// only fail a switch, not report a false success.
    static func bindings(from stored: [String: Any]) -> DesktopHotKeyBindings {
        var bindings: [Int: DesktopHotKeyBinding] = [:]
        for number in 1...9 {
            let key = String(firstHotKeyID + number - 1)
            guard let entry = stored[key] as? [String: Any] else {
                bindings[number] = DesktopHotKeyBinding(
                    keyCode: defaultKeyCodes[number - 1],
                    modifiers: controlModifier
                )
                continue
            }
            guard (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = (parameters[1] as? NSNumber)?.uint16Value,
                  let modifiers = (parameters[2] as? NSNumber)?.uint32Value else {
                continue
            }
            bindings[number] = DesktopHotKeyBinding(keyCode: keyCode, modifiers: modifiers)
        }
        return DesktopHotKeyBindings(bindings: bindings)
    }
}

/// Global ordinary-Space order across every display.
///
/// The system hotkey acts on the Nth desktop of the *global* order, which the
/// evaluation (§10.2 note 1) found is independent of the pointer and of the
/// key window. The overview only models the main display, so the navigation
/// service asks for this order separately.
protocol DesktopSpaceOrderReading {
    /// Ordinary Space IDs, display by display, in the order the system uses.
    func globalOrdinarySpaceOrder() async -> [UInt64]
}

extension DesktopSpaceService: DesktopSpaceOrderReading {}

/// Verifies that a switch actually landed.
///
/// The evaluation (§9.3) rejected "the getter matched" as proof, and §10.6
/// asks for the closed loop: public state, the target's windows on screen and
/// the target app frontmost. An empty desktop has no window to look for, so
/// only the first two signals apply there.
protocol DesktopSwitchConfirming {
    /// - Parameters:
    ///   - windowIDs: windows the snapshot says live on the target desktop.
    ///   - ownerPID: the app the switch activated, if any.
    func confirm(number: Int, windowIDs: Set<CGWindowID>, ownerPID: pid_t?) async -> Bool
}

final class SystemDesktopSwitchConfirmer: DesktopSwitchConfirming {
    private let currentDesktop: DesktopCurrentDesktopReading

    init(currentDesktop: DesktopCurrentDesktopReading = DesktopSpaceService.shared) {
        self.currentDesktop = currentDesktop
    }

    func confirm(number: Int, windowIDs: Set<CGWindowID>, ownerPID: pid_t?) async -> Bool {
        guard await currentDesktop.currentDesktopNumber() == number else { return false }
        // An empty desktop has nothing on screen to verify; reaching it is the
        // whole outcome.
        guard !windowIDs.isEmpty else { return true }
        guard windowIDs.contains(where: Self.onscreenWindowIDs().contains) else { return false }
        guard let ownerPID else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
    }

    /// Layer-zero windows currently reported as on screen.
    static func onscreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return entry[kCGWindowNumber as String] as? CGWindowID
        })
    }
}

protocol DesktopNavigationServiceProtocol: AnyObject {
    /// Resolves the target of a swipe without switching.
    func targetNumber(from current: Int, direction: SwipeDirection) -> Int?
    /// Switches to an already-validated desktop number.
    func navigate(to number: Int, snapshot: DesktopSpaceSnapshot) async -> DesktopNavigationResult
}

final class DesktopNavigationService: DesktopNavigationServiceProtocol {
    static let shared = DesktopNavigationService()

    /// How long the confirmation loop waits for the Space to actually change.
    /// Path D takes ~0.75 s end to end (evaluation §10.2), so 3 s leaves room
    /// for a busy WindowServer without masking a real failure.
    static let confirmationTimeout: TimeInterval = 3
    static let confirmationInterval: TimeInterval = 0.15

    private let switcher: DesktopSwitching
    private let hotKeys: DesktopHotKeyReading
    private let order: DesktopSpaceOrderReading
    private let confirmer: DesktopSwitchConfirming

    init(
        switcher: DesktopSwitching = SystemDesktopSwitcher(),
        hotKeys: DesktopHotKeyReading = SystemDesktopHotKeyReader(),
        order: DesktopSpaceOrderReading = DesktopSpaceService.shared,
        confirmer: DesktopSwitchConfirming = SystemDesktopSwitchConfirmer()
    ) {
        self.switcher = switcher
        self.hotKeys = hotKeys
        self.order = order
        self.confirmer = confirmer
    }

    // MARK: - Pure mapping

    /// Maps a swipe to the neighbouring grid cell. Returns nil at the edge:
    /// the nine-cell grid does not wrap (design spec §10).
    func targetNumber(from current: Int, direction: SwipeDirection) -> Int? {
        guard (1...9).contains(current) else { return nil }
        let column = (current - 1) % 3 + direction.columnDelta
        let row = (current - 1) / 3 + direction.rowDelta
        guard (0..<3).contains(column), (0..<3).contains(row) else { return nil }
        return row * 3 + column + 1
    }

    // MARK: - Navigation

    func navigate(to number: Int, snapshot: DesktopSpaceSnapshot) async -> DesktopNavigationResult {
        guard (1...9).contains(number) else {
            return .failed(reason: "out_of_range")
        }
        guard let desktop = snapshot.slot(number) else {
            AppLogger.info("Desktop switch cancelled. target=\(number), reason=not_created")
            return .notCreated(number: number)
        }
        if desktop.isCurrent {
            return .switched(number: number, path: .unavailable, confirmed: true)
        }

        let path: DesktopSwitchPath
        var activatedPID: pid_t?
        if let window = desktop.windows.first {
            activatedPID = window.ownerPID
            path = .applicationActivation
            do {
                try await switcher.activateApplication(pid: window.ownerPID)
            } catch {
                AppLogger.error(
                    "Desktop switch failed. target=\(number), path=\(path.rawValue), error=\(error)"
                )
                return .failed(reason: "activation_failed")
            }
        } else {
            path = .systemHotKey
            guard let binding = await resolvedHotKey(for: desktop) else {
                AppLogger.warning(
                    "Desktop switch unavailable. target=\(number), reason=hotkey_not_configured"
                )
                return .failed(reason: "hotkey_not_configured")
            }
            guard switcher.postSystemHotKey(binding) else {
                AppLogger.warning(
                    "Desktop switch failed. target=\(number), path=\(path.rawValue), reason=event_post_denied"
                )
                return .failed(reason: "event_post_denied")
            }
        }

        let started = Date()
        let confirmed = await waitForArrival(
            number: number,
            windowIDs: Set(desktop.windows.map(\.id)),
            ownerPID: activatedPID
        )
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        AppLogger.info(
            "Desktop switch. target=\(number), path=\(path.rawValue), confirmed=\(confirmed), elapsedMs=\(elapsed)"
        )
        return .switched(number: number, path: path, confirmed: confirmed)
    }

    /// The user may have rebound ⌃1–9 (R7), so the binding always comes from
    /// the live preferences, and the N is computed from the current global
    /// order rather than from the grid number.
    private func resolvedHotKey(for desktop: Desktop) async -> DesktopHotKeyBinding? {
        let bindings = hotKeys.readBindings()
        guard bindings.isAvailable else { return nil }

        let order = await order.globalOrdinarySpaceOrder()
        guard let index = order.firstIndex(of: desktop.id) else { return nil }
        let globalNumber = index + 1
        guard let binding = bindings[globalNumber] else {
            AppLogger.warning(
                "Desktop hotkey not configured. globalNumber=\(globalNumber), configured=\(bindings.bindings.keys.sorted())"
            )
            return nil
        }
        return binding
    }

    /// Polls the closed-loop check until it passes or the budget runs out.
    /// An unconfirmed switch is reported as such rather than claimed.
    private func waitForArrival(
        number: Int,
        windowIDs: Set<CGWindowID>,
        ownerPID: pid_t?
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.confirmationTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await confirmer.confirm(number: number, windowIDs: windowIDs, ownerPID: ownerPID) {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.confirmationInterval * 1_000_000_000))
        }
        return false
    }
}
