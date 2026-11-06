//
//  InstalledAppsService.swift
//  Switchly
//
//  The list of apps a user can add to a workspace or to the monitored set.
//

import AppKit
import Foundation

/// The two fields every app picker searches.
///
/// `MonitoredApp` (preferences) and `WorkspaceAppItem` (workspaces) both carry
/// them, so the shared search below can serve both without converting one list
/// into the other.
protocol AppIdentity {
    var bundleIdentifier: String { get }
    var appName: String { get }
}

/// The two pickers' item types search through the shared predicate below.
///
/// Declared here rather than in each model so the contract lives next to the
/// code that relies on it.
extension MonitoredApp: AppIdentity {}
extension WorkspaceAppItem: AppIdentity {}

/// One app the user can add, wherever it is installed.
///
/// Identified by bundle id *and* name: two products can share a bundle id
/// (ChatGPT and ChatGPT Atlas both ship `com.openai.chat`), and collapsing them
/// would make one of them impossible to add.
struct InstalledApp: Identifiable, Hashable, AppIdentity {
    let bundleIdentifier: String
    let appName: String

    var id: String { "\(bundleIdentifier)|\(appName)" }
}

/// Enumerates the applications installed on this Mac.
///
/// Both app pickers used to be hand-rolled from
/// `NSWorkspace.shared.runningApplications`, which produced exactly the symptom
/// of "I cannot find my app":
///
/// 1. an app that is installed but not running is simply absent — a freshly
///    installed browser, or one not opened since boot, could not be added at all;
/// 2. every bundle id starting with `com.apple.` was filtered out, so no Apple
///    app (Safari, Terminal, Xcode, Mail, …) could ever be added.
///
/// This service reads the standard application directories instead, merges in
/// anything that is running from elsewhere, and re-enumerates when apps launch
/// or quit so the list cannot go stale behind an open window.
final class InstalledAppsService {
    static let shared = InstalledAppsService()

    /// Posted on the main thread after the enumerated list changes.
    static let didChangeNotification = Notification.Name("InstalledAppsDidChange")

    /// Directories scanned for `.app` bundles, most specific first. Duplicates
    /// are removed by resolved path, so overlapping entries cost nothing.
    static let applicationDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path,
        "/System/Library/CoreServices"
    ]

    private let lock = NSLock()
    private var cachedApps: [InstalledApp] = []
    private var isObservingLaunches = false
    /// Coalesces the launch/terminate burst that follows an app switcher into a
    /// single enumeration.
    private var pendingReload: DispatchWorkItem?

    private init() {}

    /// The last enumerated list. Empty until the first `reload()` completes.
    var apps: [InstalledApp] {
        lock.lock()
        defer { lock.unlock() }
        return cachedApps
    }

    /// Enumerates off the main thread and publishes the result on the main one.
    ///
    /// Reading a few hundred Info.plist files is cheap but not free, and the
    /// pickers are opened from a click, so this never blocks the caller.
    func reload() {
        startObservingLaunches()
        let excludedBundleID = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = Self.enumerate(excluding: excludedBundleID)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.lock.lock()
                self.cachedApps = apps
                self.lock.unlock()
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }

    // MARK: - Enumeration

    /// Every app in `directories`, plus every running app, deduplicated.
    ///
    /// Both `directories` and `runningApps` are parameters so the tests can point
    /// at fixtures instead of the real machine; the defaults are the standard
    /// directories and the machine's running applications.
    static func enumerate(
        directories: [String] = applicationDirectories,
        runningApps: [NSRunningApplication] = NSWorkspace.shared.runningApplications,
        excluding excludedBundleID: String?
    ) -> [InstalledApp] {
        let fileManager = FileManager.default
        var found: [InstalledApp] = []
        var seenPaths = Set<String>()

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard seenPaths.insert(path).inserted else {
                    continue
                }
                if let app = makeApp(atPath: path) {
                    found.append(app)
                }
            }
        }

        // Apps that are running from somewhere the scan above does not cover: a
        // bundle the user moved, a TestFlight build, a disk image. They are
        // addable today, so they must stay addable.
        for running in runningApps {
            guard let bundleIdentifier = running.bundleIdentifier,
                  let path = running.bundleURL?.path,
                  let appName = running.localizedName,
                  seenPaths.insert(path).inserted else {
                continue
            }
            found.append(InstalledApp(bundleIdentifier: bundleIdentifier, appName: appName))
        }

        return dedupeAndSort(found, excluding: excludedBundleID)
    }

    /// Reads one `.app` bundle's identity.
    ///
    /// Returns nil for a bundle with no bundle identifier: such an app cannot be
    /// launched by id, and the pickers would show a row that can never work.
    static func makeApp(atPath path: String) -> InstalledApp? {
        guard let bundle = Bundle(path: path),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        return InstalledApp(
            bundleIdentifier: bundleIdentifier,
            appName: displayName(for: bundle, atPath: path)
        )
    }

    /// Characters that render as nothing: bidi marks, zero-width joiners, the
    /// BOM. At least two bundles Apple ships (`com.apple.MediaRemoteUI` and its
    /// service) carry a display name that is a single LEFT-TO-RIGHT MARK, which
    /// shows up as a blank row in the picker.
    private static let invisibleScalars: Set<UInt32> = [
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF
    ]

    /// A name with the characters that render as nothing removed, or nil when
    /// nothing visible is left.
    static func visibleName(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { !invisibleScalars.contains($0.value) }
        guard !scalars.isEmpty else {
            return nil
        }
        let name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Name the picker shows: the localized display name, then the bundle name,
    /// then the file name without its extension.
    ///
    /// `localizedInfoDictionary` matters here — it is what returns the name in
    /// the user's language, which is what the user will type into the search box.
    static func displayName(for bundle: Bundle, atPath path: String) -> String {
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info?[key] as? String, let visible = visibleName(value) {
                return visible
            }
        }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// One entry per (bundle id, name) pair, sorted by localized name.
    static func dedupeAndSort(
        _ apps: [InstalledApp],
        excluding excludedBundleID: String?
    ) -> [InstalledApp] {
        var seen = Set<String>()
        return apps
            .filter { app in
                guard app.bundleIdentifier != excludedBundleID else {
                    return false
                }
                return seen.insert(app.id).inserted
            }
            .sorted {
                $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
    }

    // MARK: - Search

    /// Case-insensitive match on name or bundle identifier.
    ///
    /// Both pickers run this, so they cannot drift into searching different
    /// fields — the workspace picker and the preferences picker used to carry
    /// their own copies of these four lines.
    static func filter<App: AppIdentity>(_ apps: [App], query: String) -> [App] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return apps
        }
        return apps.filter {
            $0.appName.lowercased().contains(trimmed)
                || $0.bundleIdentifier.lowercased().contains(trimmed)
        }
    }

    // MARK: - Keeping the list warm

    /// Re-enumerates shortly after an app launches or quits.
    ///
    /// Without this the list is a snapshot taken when the picker's view model
    /// was created, so an app installed or removed while the window is open
    /// stays missing until the window is reopened.
    private func startObservingLaunches() {
        guard !isObservingLaunches else {
            return
        }
        isObservingLaunches = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleReload()
            }
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}
