//
//  InstalledAppsServiceTests.swift
//  SwitchlyTests
//
//  Unit tests for the installed-app enumeration behind both app pickers.
//
//  The regression these lock down is the one the user hit: the pickers were
//  built from `NSWorkspace.shared.runningApplications` and dropped every
//  `com.apple.*` bundle, so an app that was installed but not running — and every
//  Apple app, Safari included — could not be found at all.
//
//  Enumeration runs against fixtures written into a temporary directory, so it
//  does not depend on what happens to be installed on this machine. Only the
//  parts that genuinely need the window server (the merge of *running* apps) are
//  asserted with `contains`, because which apps run during a test run is not the
//  test's business.
//

import XCTest
import AppKit
@testable import Switchly

final class InstalledAppsServiceTests: XCTestCase {

    private var fixtureRoot: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledAppsServiceTests-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(atPath: fixtureRoot)
        }
        fixtureRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Writes `<directory>/<name>.app/Contents/Info.plist`.
    ///
    /// Keys left nil are omitted, which is how a bundle without a bundle
    /// identifier (or without a name) is produced.
    @discardableResult
    private func makeAppBundle(
        directory: String,
        name: String,
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        bundleName: String? = nil
    ) throws -> String {
        let appPath = (directory as NSString).appendingPathComponent("\(name).app")
        let contentsPath = (appPath as NSString).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(atPath: contentsPath, withIntermediateDirectories: true)

        var info: [String: String] = [:]
        if let bundleIdentifier { info["CFBundleIdentifier"] = bundleIdentifier }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if let bundleName { info["CFBundleName"] = bundleName }

        let plistPath = (contentsPath as NSString).appendingPathComponent("Info.plist")
        try (info as NSDictionary).write(to: URL(fileURLWithPath: plistPath), atomically: true)
        return appPath
    }

    // MARK: - Enumeration

    /// The reported bug in two assertions: an app nobody is running must be
    /// enumerable, and an Apple app must survive.
    func testEnumerateFindsAppsThatAreNotRunningAndAppleAppsToo() throws {
        try makeAppBundle(directory: fixtureRoot, name: "NotRunning", bundleIdentifier: "com.example.notrunning")
        try makeAppBundle(directory: fixtureRoot, name: "Safari", bundleIdentifier: "com.apple.Safari")

        let apps = InstalledAppsService.enumerate(
            directories: [fixtureRoot],
            runningApps: [],
            excluding: "com.switchly.app"
        )

        XCTAssertTrue(
            apps.contains { $0.bundleIdentifier == "com.example.notrunning" },
            "an installed app that is not running must be addable"
        )
        XCTAssertTrue(
            apps.contains { $0.bundleIdentifier == "com.apple.Safari" },
            "Apple apps must not be filtered out by their bundle id"
        )
    }

    func testEnumerateIgnoresFilesThatAreNotAppBundles() throws {
        try makeAppBundle(directory: fixtureRoot, name: "RealApp", bundleIdentifier: "com.example.real")
        try "not an app".write(
            to: URL(fileURLWithPath: (fixtureRoot as NSString).appendingPathComponent("README.txt")),
            atomically: true,
            encoding: .utf8
        )

        let apps = InstalledAppsService.enumerate(
            directories: [fixtureRoot],
            runningApps: [],
            excluding: nil
        )

        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.real"], "a .txt file must not become an addable app")
    }

    /// A bundle with no bundle identifier cannot be launched by id, so the
    /// pickers must not offer it as a row that can never work.
    func testBundleWithoutAnIdentifierIsSkipped() throws {
        try makeAppBundle(directory: fixtureRoot, name: "NoIdentifier", bundleName: "Still Named")

        let apps = InstalledAppsService.enumerate(
            directories: [fixtureRoot],
            runningApps: [],
            excluding: nil
        )

        XCTAssertTrue(apps.isEmpty, "a bundle with no bundle identifier must not be offered")
    }

    /// A missing directory is normal (not every Mac has ~/Applications), and it
    /// must not abort the whole enumeration.
    func testMissingDirectoryIsSkipped() throws {
        try makeAppBundle(directory: fixtureRoot, name: "Present", bundleIdentifier: "com.example.present")

        let apps = InstalledAppsService.enumerate(
            directories: ["/nonexistent/applications", fixtureRoot],
            runningApps: [],
            excluding: nil
        )

        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.present"])
    }

    func testSwitchlyItselfIsNeverOffered() throws {
        try makeAppBundle(directory: fixtureRoot, name: "Switchly", bundleIdentifier: "com.switchly.app")
        try makeAppBundle(directory: fixtureRoot, name: "Other", bundleIdentifier: "com.example.other")

        let apps = InstalledAppsService.enumerate(
            directories: [fixtureRoot],
            runningApps: [],
            excluding: "com.switchly.app"
        )

        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.other"])
    }

    /// The merge exists for apps that live outside the scanned directories — a
    /// bundle the user moved, a TestFlight build, a disk image. The test host is
    /// exactly that: it runs from DerivedData, not from /Applications, so it can
    /// only be in the list through the running-app merge.
    func testEnumerateMergesRunningAppsFromOutsideTheScannedDirectories() {
        let ownBundleID = Bundle.main.bundleIdentifier

        let merged = InstalledAppsService.enumerate(directories: [fixtureRoot], excluding: nil)
        XCTAssertTrue(
            merged.contains { $0.bundleIdentifier == ownBundleID },
            "a running app outside the scanned directories must stay addable"
        )

        let excluded = InstalledAppsService.enumerate(
            directories: [fixtureRoot],
            excluding: ownBundleID
        )
        XCTAssertFalse(
            excluded.contains { $0.bundleIdentifier == ownBundleID },
            "Switchly itself must never be offered, even through the merge"
        )
    }



    /// `visibleName` removes the characters that render as nothing.
    func testVisibleNameStripsInvisibleCharacters() {
        XCTAssertEqual(InstalledAppsService.visibleName("\u{200E}Safari\u{200F}"), "Safari")
        XCTAssertEqual(InstalledAppsService.visibleName("Safari"), "Safari")
        XCTAssertEqual(InstalledAppsService.visibleName("  Safari  "), "Safari")
    }

    /// A name that is nothing but invisible characters has no visible content, so
    /// the caller must fall through to its next candidate.
    func testVisibleNameReportsNothingForAnAllInvisibleName() {
        XCTAssertNil(InstalledAppsService.visibleName("\u{200E}"))
        XCTAssertNil(InstalledAppsService.visibleName(""))
        XCTAssertNil(InstalledAppsService.visibleName("   "))
        XCTAssertNil(InstalledAppsService.visibleName("\u{FEFF}"))
    }

    /// The real case: `com.apple.MediaRemoteUI` ships a display name that is a
    /// single LEFT-TO-RIGHT MARK, which used to show up as a blank row.
    func testDisplayNameFallsBackWhenTheBundleNameIsInvisible() throws {
        let path = try makeAppBundle(
            directory: fixtureRoot,
            name: "MediaRemoteUI",
            bundleIdentifier: "com.apple.MediaRemoteUI",
            displayName: "\u{200E}",
            bundleName: "Media Remote UI"
        )

        let app = try XCTUnwrap(InstalledAppsService.makeApp(atPath: path))
        XCTAssertEqual(app.appName, "Media Remote UI")
    }
    // MARK: - Display name

    func testDisplayNamePrefersTheLocalizedDisplayName() throws {
        let path = try makeAppBundle(
            directory: fixtureRoot,
            name: "Zed",
            bundleIdentifier: "dev.zed.app",
            displayName: "Zed Editor",
            bundleName: "ZedInternalBinaryName"
        )

        let app = try XCTUnwrap(InstalledAppsService.makeApp(atPath: path))

        XCTAssertEqual(app.appName, "Zed Editor")
        XCTAssertEqual(app.bundleIdentifier, "dev.zed.app")
    }

    func testDisplayNameFallsBackToBundleName() throws {
        let path = try makeAppBundle(
            directory: fixtureRoot,
            name: "Named",
            bundleIdentifier: "com.example.named",
            bundleName: "Fallback Name"
        )

        XCTAssertEqual(try XCTUnwrap(InstalledAppsService.makeApp(atPath: path)).appName, "Fallback Name")
    }

    func testDisplayNameFallsBackToTheFileName() throws {
        let path = try makeAppBundle(
            directory: fixtureRoot,
            name: "PlainApp",
            bundleIdentifier: "com.example.plain"
        )

        XCTAssertEqual(try XCTUnwrap(InstalledAppsService.makeApp(atPath: path)).appName, "PlainApp")
    }

    // MARK: - Dedup and sort

    /// ChatGPT and ChatGPT Atlas ship the same bundle id; collapsing them would
    /// make one of the two impossible to add.
    func testDedupeKeepsProductsThatShareABundleIdentifier() {
        let apps = InstalledAppsService.dedupeAndSort([
            InstalledApp(bundleIdentifier: "com.openai.chat", appName: "ChatGPT"),
            InstalledApp(bundleIdentifier: "com.openai.chat", appName: "ChatGPT Atlas"),
            InstalledApp(bundleIdentifier: "com.openai.chat", appName: "ChatGPT")
        ], excluding: nil)

        XCTAssertEqual(apps.map(\.appName), ["ChatGPT", "ChatGPT Atlas"])
    }

    func testDedupeSortsByLocalizedNameIgnoringCase() {
        let apps = InstalledAppsService.dedupeAndSort([
            InstalledApp(bundleIdentifier: "b", appName: "zeta"),
            InstalledApp(bundleIdentifier: "a", appName: "Alpha"),
            InstalledApp(bundleIdentifier: "c", appName: "beta")
        ], excluding: nil)

        XCTAssertEqual(apps.map(\.appName), ["Alpha", "beta", "zeta"])
    }

    // MARK: - Search

    func testFilterMatchesNameOrBundleIdentifierCaseInsensitively() {
        let apps = [
            InstalledApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"),
            InstalledApp(bundleIdentifier: "org.mozilla.firefox", appName: "Firefox")
        ]

        XCTAssertEqual(InstalledAppsService.filter(apps, query: "saf").map(\.appName), ["Safari"])
        XCTAssertEqual(InstalledAppsService.filter(apps, query: "SAFARI").map(\.appName), ["Safari"])
        XCTAssertEqual(InstalledAppsService.filter(apps, query: "com.apple.safari").map(\.appName), ["Safari"])
        XCTAssertEqual(InstalledAppsService.filter(apps, query: "mozilla").map(\.appName), ["Firefox"])
        XCTAssertTrue(InstalledAppsService.filter(apps, query: "nothingmatches").isEmpty)
    }

    func testFilterWithAnEmptyQueryReturnsEverything() {
        let apps = [
            InstalledApp(bundleIdentifier: "a", appName: "Alpha"),
            InstalledApp(bundleIdentifier: "b", appName: "Beta")
        ]

        XCTAssertEqual(InstalledAppsService.filter(apps, query: "").count, 2)
        XCTAssertEqual(InstalledAppsService.filter(apps, query: "   ").count, 2)
    }

    /// Both pickers search their own item type through this one predicate, so
    /// the workspace picker and the preferences picker cannot drift apart.
    func testFilterServesBothPickerItemTypes() {
        let monitored = [MonitoredApp(bundleIdentifier: "com.apple.Safari", appName: "Safari")]
        XCTAssertEqual(InstalledAppsService.filter(monitored, query: "saf").count, 1)

        let workspaceItems = [WorkspaceAppItem(bundleIdentifier: "com.apple.Safari", appName: "Safari")]
        XCTAssertEqual(InstalledAppsService.filter(workspaceItems, query: "com.apple.safari").count, 1)
    }
}
