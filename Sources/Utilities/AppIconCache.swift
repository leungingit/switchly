//
//  AppIconCache.swift
//  Switchly
//
//  Process-wide cache for application icons.
//
//  `NSRunningApplication.icon` and `NSWorkspace.icon(forFile:)` both go
//  through LaunchServices on every call. Card bodies used to call them on
//  every re-evaluation (hover, selection changes, settings changes), which
//  multiplied the lookup cost by the number of visible cards — dozens of
//  LaunchServices round-trips per pointer move across the grid.
//
//  Icons are immutable for the lifetime of a process / bundle, so a plain
//  cache removes the repeated work entirely. NSCache is thread-safe and
//  evicts under memory pressure on its own.
//

import AppKit

enum AppIconCache {

    private static let pidIcons = NSCache<NSNumber, NSImage>()
    private static let bundleIcons = NSCache<NSString, NSImage>()
    private static let nameIcons = NSCache<NSString, NSImage>()

    /// Icon of the running application that owns `pid`, or nil when the
    /// process is gone.
    ///
    /// Keyed by process identifier: a card only ever asks for the icon of a
    /// process that currently owns one of its windows, so a recycled pid can
    /// never surface a stale icon for a live card.
    static func icon(forPID pid: pid_t) -> NSImage? {
        let key = NSNumber(value: pid)
        if let cached = pidIcons.object(forKey: key) {
            return cached
        }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else {
            return nil
        }
        pidIcons.setObject(icon, forKey: key)
        return icon
    }

    /// Icon of the installed application with `bundleIdentifier`, or nil
    /// when the app is not installed.
    static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        if let cached = bundleIcons.object(forKey: bundleIdentifier as NSString) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        bundleIcons.setObject(icon, forKey: bundleIdentifier as NSString)
        return icon
    }

    /// Icon of the running application whose localized name matches
    /// `appName`, or nil.
    ///
    /// Used by the dock preview header, which only knows the Dock AX title
    /// (no bundle identifier). Resolving it walks `runningApplications`, so
    /// the result is cached per name — the header re-renders on every hover.
    static func icon(forAppName appName: String) -> NSImage? {
        if let cached = nameIcons.object(forKey: appName as NSString) {
            return cached
        }
        guard let icon = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == appName })?.icon else {
            return nil
        }
        nameIcons.setObject(icon, forKey: appName as NSString)
        return icon
    }
}
