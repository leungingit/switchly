//
//  AppActivationTracker.swift
//  Switchly
//
//  Remembers when each app was last in front, so a Dock preview plugin can tell what
//  happened since the user last looked at that app (`ctx.app.lastActiveAt`).
//  History starts when Switchly starts; before that an app's time is unknown.
//

import AppKit
import Foundation

protocol AppActivationTracking: AnyObject {
    /// Now if the app is frontmost, the moment it stopped being frontmost otherwise, nil if never seen.
    func lastActiveAt(bundleID: String) -> Date?
}

final class AppActivationTracker: AppActivationTracking {
    static let shared = AppActivationTracker()

    private let center: NotificationCenter
    private let now: () -> Date
    private let lock = NSLock()
    private var frontmost: String?
    private var leftFront: [String: Date] = [:]
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
         now: @escaping () -> Date = Date.init) {
        self.center = center
        self.frontmost = frontmost
        self.now = now
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Safe to call repeatedly.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard observer == nil else { return }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(bundleID: app?.bundleIdentifier)
        }
    }

    func activated(bundleID: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard bundleID != frontmost else { return }
        if let previous = frontmost { leftFront[previous] = now() }
        frontmost = bundleID
    }

    func lastActiveAt(bundleID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return frontmost == bundleID ? now() : leftFront[bundleID]
    }
}
