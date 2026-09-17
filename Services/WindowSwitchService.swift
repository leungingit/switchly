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

    /// Activation is asynchronous and can race with the AppKit transition that
    /// happens when our own preview panel closes, so it is re-asserted.
    private static let activationAttempts = 5
    private static let activationRetryDelay: UInt64 = 100_000_000

    func switchToWindow(_ window: WindowInfo) async throws {
        AppLogger.info("Switching to window. windowID=\(window.id), owner=\(window.ownerName), title=\"\(window.windowTitle)\", bounds=\(window.bounds)")
        try await switchToApplication(pid: window.ownerPID)
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
        // that proves which element was raised.
        guard AccessibilityService.shared.resolveAndFocus(window) else {
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
