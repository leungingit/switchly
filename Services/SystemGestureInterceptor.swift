//
//  SystemGestureInterceptor.swift
//  Switchly
//
//  Swallows the Dock's four-finger swipe events so the grid answers instead
//  of the system, without touching the user's trackpad preferences.
//
//  Measured on macOS 27.0.1 (2026-10-23): every system four-finger swipe
//  (switch desktop, Mission Control, App Exposé) arrives as event type 30
//  with field 110 == 23; dropping them at a session tap stops the system
//  response in all directions. Type 30 is undocumented, so on another
//  release the tap may see nothing and both responders fire again.
//  Removing the tap restores the system gesture at once.
//

import Foundation
import CoreGraphics

protocol SystemGestureIntercepting: AnyObject {
    var isIntercepting: Bool { get }
    /// Returns false when the tap cannot be created (no Accessibility).
    @discardableResult
    func start() -> Bool
    func stop()
}

final class SystemGestureInterceptor: SystemGestureIntercepting {
    static let shared = SystemGestureInterceptor()

    /// Undocumented CGEventType carrying the Dock's swipe gestures.
    static let dockGestureEventType: UInt32 = 30

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isIntercepting: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << CGEventMask(Self.dockGestureEventType)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // The system disables a slow tap; turn it back on so
                    // interception survives a busy main thread.
                    if let userInfo {
                        let owner = Unmanaged<SystemGestureInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        AppLogger.warning("System gesture tap re-enabled. reason=\(type.rawValue)")
                    }
                    return Unmanaged.passUnretained(event)
                }
                return type.rawValue == SystemGestureInterceptor.dockGestureEventType
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLogger.warning("System gesture interception unavailable. reason=tap_create_failed")
            return false
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = runLoopSource
        AppLogger.info("System gesture interception started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        AppLogger.info("System gesture interception stopped")
    }
}
