//
//  WindowSwitchService.swift
//  Switchly
//
//  Service for switching between application windows
//

import Foundation
import AppKit
import CoreGraphics

protocol WindowSwitchServiceProtocol {
    func switchToWindow(_ window: WindowInfo) async throws
    func switchToApplication(pid: pid_t) async throws
}

class WindowSwitchService: WindowSwitchServiceProtocol {
    static let shared = WindowSwitchService()

    /// Serial queue for the synchronous, sleep-based AX focus pipeline. That
    /// pipeline parks its thread in `Thread.sleep` and AX messaging timeouts
    /// for up to ~1.2 s by design; running it on the caller's executor would
    /// block a Swift-concurrency cooperative thread for the whole duration
    /// (and several concurrent switches could starve the pool). A dedicated
    /// serial queue also keeps concurrent switches from interleaving their
    /// raise/verify cycles.
    private static let focusQueue = DispatchQueue(
        label: "com.switchly.windowFocus",
        qos: .userInitiated
    )

    /// Activation is asynchronous and can race with the AppKit transition that
    /// happens when our own preview panel closes, so it is re-asserted.
    private static let activationAttempts = 5
    private static let activationRetryDelay: UInt64 = 100_000_000

    func switchToWindow(_ window: WindowInfo) async throws {
        AppLogger.info("Switching to window. windowID=\(window.id), owner=\(window.ownerName), title=\"\(window.windowTitle)\", bounds=\(window.bounds)")
        // Activating the app first makes macOS jump to the desktop of its most
        // recently active window, so a target on another desktop would flash
        // that desktop before the window is brought forward. The other-space
        // path fronts the exact window itself and needs no prior activation;
        // the same-desktop path re-asserts activation per attempt.
        if !window.isOnOtherSpace || window.isMinimized {
            try await switchToApplication(pid: window.ownerPID)
        }
        try await focusWindow(window)
    }

    func switchToApplication(pid: pid_t) async throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            AppLogger.error("Cannot switch to application. pid=\(pid) not found")
            throw SwitchError.applicationNotFound
        }

        AppLogger.info("Activating application. pid=\(pid), name=\(app.localizedName ?? "nil"), bundleID=\(app.bundleIdentifier ?? "nil")")
        for attempt in 1...Self.activationAttempts {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return
            }
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: Self.activationRetryDelay)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return
            }
            AppLogger.debug("Target application is not frontmost yet. pid=\(pid), attempt=\(attempt)")
        }

        // Raising a window of a non-frontmost app is a no-op on most apps, so
        // this is worth flagging even though the raise is still attempted.
        AppLogger.warning("Target application did not become frontmost after retries. pid=\(pid), continuing with the window raise")
    }

    private func focusWindow(_ window: WindowInfo) async throws {
        // Identification, the raise and the CoreGraphics verification all live in
        // the service: a wrong guess has to rotate to another element instead of
        // aborting the switch, and only the service can see the window ordering
        // that proves which element was raised. The synchronous pipeline runs
        // on `focusQueue` — see its declaration for why not the caller's
        // executor — and is awaited here as one unit.
        let focused = await withCheckedContinuation { continuation in
            Self.focusQueue.async {
                continuation.resume(returning: AccessibilityService.shared.resolveAndFocus(window))
            }
        }
        guard focused else {
            throw SwitchError.accessibilityFailed("Unable to focus window \(window.id)")
        }
    }
}

extension CGError {
    var localizedDescription: String {
        return "CoreGraphics error: \(rawValue)"
    }
}

enum SwitchError: LocalizedError {
    case applicationNotFound
    case accessibilityFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return NSLocalizedString("Application not found", comment: "")
        case .accessibilityFailed(let msg):
            return String(format: NSLocalizedString("Accessibility error: %@", comment: ""), msg)
        }
    }
}
