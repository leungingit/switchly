import XCTest
@testable import Switchly

/// `fs.read` (design doc §8.6): everything runs against a throwaway "home" folder, never real user files.
final class PluginFileReaderTests: XCTestCase {
    private var home: URL!
    private var root: URL { home.appendingPathComponent(".sessions") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("fsread-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "deep".write(to: root.appendingPathComponent("nested/b.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func reader(path: String = "~/.sessions") -> PluginFileReader {
        PluginFileReader(roots: [PluginFSRoot(id: "s", path: path, summary: [:])], home: home)
    }

    func testReadsListsAndStatsInsideTheRoot() throws {
        let r = reader()
        XCTAssertEqual(try r.readText(root: "s", path: "a.txt"), "hello")
        XCTAssertEqual(try r.readText(root: "s", path: "nested/b.txt"), "deep")
        XCTAssertEqual(try r.list(root: "s", path: "").map(\.name), ["a.txt", "nested"])
        XCTAssertEqual(try r.list(root: "s", path: "").map(\.isDirectory), [false, true])
        let stat = try r.stat(root: "s", path: "a.txt")
        XCTAssertEqual(stat.size, 5)
        XCTAssertGreaterThan(stat.modified, 0)
    }

    func testUnsafePathsAreDenied() {
        let r = reader()
        for path in ["../x", "nested/../../x", "/etc/passwd", "a//b", "a.txt/", "x\0y"] {
            XCTAssertThrowsError(try r.readText(root: "s", path: path), path) { XCTAssertEqual($0 as? PluginFSError, .denied, path) }
        }
        XCTAssertThrowsError(try r.readText(root: "other", path: "a.txt")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
        XCTAssertThrowsError(try r.readText(root: "s", path: "missing.txt")) { XCTAssertEqual($0 as? PluginFSError, .notFound) }
    }

    func testSymlinksLeavingTheRootAreDenied() throws {
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir-link"), withDestinationURL: outside)
        let r = reader()
        XCTAssertThrowsError(try r.readText(root: "s", path: "file-link")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
        XCTAssertThrowsError(try r.readText(root: "s", path: "dir-link/s.txt")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
        XCTAssertThrowsError(try r.stat(root: "s", path: "dir-link")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
        XCTAssertEqual(try r.list(root: "s", path: "").map(\.name), ["a.txt", "nested"], "links that leave the root are hidden")
    }

    func testRootThatIsALinkToASensitiveFolderIsDenied() throws {
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".innocent"), withDestinationURL: ssh)
        XCTAssertThrowsError(try reader(path: "~/.innocent").list(root: "s", path: "")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
    }

    func testSensitiveAndTooBroadRootsAreRejected() {
        for path in ["~/.ssh", "~/.aws/sso", "~/.codex", "~/Library/Keychains", "~", "/", "/etc", "~/../x"] {
            XCTAssertFalse(PluginFSRoot(id: "s", path: path, summary: [:]).isAcceptable(home: home), path)
            XCTAssertThrowsError(try reader(path: path).list(root: "s", path: "")) { XCTAssertEqual($0 as? PluginFSError, .denied, path) }
        }
        XCTAssertTrue(PluginFSRoot(id: "s", path: "~/.dsh", summary: [:]).isAcceptable(home: home))
    }

    func testFolderHoldingCredentialsIsDenied() throws {
        try "{}".write(to: root.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try reader().readText(root: "s", path: "a.txt")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
    }

    func testSizeAndEncodingLimits() throws {
        try Data(repeating: 0x61, count: PluginFileReader.maxReadBytes + 1).write(to: root.appendingPathComponent("big.txt"))
        try Data([0xFF, 0xFE, 0x00]).write(to: root.appendingPathComponent("bin.dat"))
        let r = reader()
        XCTAssertThrowsError(try r.readText(root: "s", path: "big.txt")) { XCTAssertEqual($0 as? PluginFSError, .tooLarge) }
        XCTAssertThrowsError(try r.readText(root: "s", path: "a.txt", maxBytes: 2)) { XCTAssertEqual($0 as? PluginFSError, .tooLarge) }
        XCTAssertThrowsError(try r.readText(root: "s", path: "bin.dat")) { XCTAssertEqual($0 as? PluginFSError, .notText) }
        XCTAssertThrowsError(try r.readText(root: "s", path: "nested")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
    }

    func testListingIsCapped() throws {
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0...PluginFileReader.maxListEntries { FileManager.default.createFile(atPath: many.appendingPathComponent("\(i)").path, contents: nil) }
        XCTAssertThrowsError(try reader().list(root: "s", path: "many")) { XCTAssertEqual($0 as? PluginFSError, .tooLarge) }
    }

    func testCallQuotaPerRenderAndReset() throws {
        let r = reader()
        for _ in 0..<PluginFileReader.maxCallsPerRender { _ = try r.stat(root: "s", path: "a.txt") }
        XCTAssertThrowsError(try r.stat(root: "s", path: "a.txt")) { XCTAssertEqual($0 as? PluginFSError, .tooManyCalls) }
        r.resetCalls()
        XCTAssertNoThrow(try r.stat(root: "s", path: "a.txt"))
    }

    func testScanFindsFilesByDepthSuffixAndAgeNewestFirst() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("w/s1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("w/s2/deeper/deepest"), withIntermediateDirectories: true)
        func put(_ rel: String, age: TimeInterval) throws {
            let url = root.appendingPathComponent(rel)
            try Data([1]).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try put("w/s1/a.jsonl.zstd", age: 10)
        try put("w/s2/b.jsonl.zstd", age: 5)
        try put("w/s2/old.jsonl.zstd", age: 100_000)
        try put("w/s2/note.txt", age: 1)
        try put("w/s2/deeper/deepest/too-deep.jsonl.zstd", age: 1)
        let r = reader()
        let found = try r.scan(root: "s", path: "", depth: 3, suffix: ".jsonl.zstd", modifiedWithin: 86_400)
        XCTAssertEqual(found.map(\.path), ["w/s2/b.jsonl.zstd", "w/s1/a.jsonl.zstd"], "newest first; old, wrong suffix and too deep are left out")
        XCTAssertEqual(try r.scan(root: "s", path: "", depth: 1, suffix: nil, modifiedWithin: nil).map(\.path), ["a.txt"])
        XCTAssertThrowsError(try r.scan(root: "s", path: "../x", depth: 1, suffix: nil, modifiedWithin: nil)) { XCTAssertEqual($0 as? PluginFSError, .denied) }
    }

    func testScanDoesNotFollowLinksOutOfTheRoot() throws {
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("leak.jsonl.zstd"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("leak.jsonl.zstd"), withDestinationURL: outside.appendingPathComponent("leak.jsonl.zstd"))
        XCTAssertEqual(try reader().scan(root: "s", path: "", depth: 3, suffix: ".jsonl.zstd", modifiedWithin: nil), [])
    }

    func testIsLockedSeesAnotherHolderOnly() throws {
        let lock = root.appendingPathComponent("session.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        let r = reader()
        XCTAssertFalse(try r.isLocked(root: "s", path: "session.lock"))
        let fd = open(lock.path, O_RDONLY)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(try r.isLocked(root: "s", path: "session.lock"))
        flock(fd, LOCK_UN)
        XCTAssertFalse(try r.isLocked(root: "s", path: "session.lock"), "the probe must not leave its own lock behind")
        XCTAssertThrowsError(try r.isLocked(root: "s", path: "nested")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
        XCTAssertThrowsError(try r.isLocked(root: "s", path: "../x")) { XCTAssertEqual($0 as? PluginFSError, .denied) }
    }

    // MARK: - Manifest and authorization

    private func manifest(permissions: [PluginCapability], roots: [PluginFSRoot]?, defaultEnabled: Bool? = nil) -> PluginManifest {
        PluginManifest(id: "com.example.fs", name: ["en": "FS"], version: "1", apiVersion: 2, matches: ["com.example.app"],
                       permissions: permissions, entry: "main.js", refreshInterval: nil, fsRoots: roots, defaultEnabled: defaultEnabled)
    }

    func testManifestNeedsRootsExactlyWhenItAsksForFsRead() {
        let ok = PluginFSRoot(id: "s", path: "~/.dsh", summary: ["en": "why"])
        XCTAssertNoThrow(try manifest(permissions: [.fsRead], roots: [ok]).validate())
        XCTAssertThrowsError(try manifest(permissions: [.fsRead], roots: nil).validate())
        XCTAssertThrowsError(try manifest(permissions: [], roots: [ok]).validate())
        XCTAssertThrowsError(try manifest(permissions: [.fsRead], roots: [ok, ok]).validate(), "duplicate ids")
        XCTAssertThrowsError(try manifest(permissions: [.fsRead], roots: [PluginFSRoot(id: "s", path: "~/.ssh", summary: [:])]).validate())
    }

    func testBuiltinPluginNeverGetsFsReadWithoutAnExplicitGrant() {
        let m = manifest(permissions: [.fsRead, .windowFocus], roots: [PluginFSRoot(id: "s", path: "~/.dsh", summary: [:])], defaultEnabled: false)
        let fresh = PluginAuthorization.resolve(manifest: m, origin: .builtin, grant: nil)
        XCTAssertFalse(fresh.isEnabled, "defaultEnabled false keeps a built-in off until the user turns it on")
        XCTAssertEqual(fresh.permissions, [.windowFocus])
        let on = PluginAuthorization.resolve(manifest: m, origin: .builtin, grant: PluginGrant(isEnabled: true, permissions: []))
        XCTAssertEqual(on.permissions, [.windowFocus])
        let allowed = PluginAuthorization.resolve(manifest: m, origin: .builtin, grant: PluginGrant(isEnabled: true, permissions: ["fs.read"]))
        XCTAssertEqual(allowed.permissions, [.fsRead, .windowFocus])
    }

    // MARK: - JS bridge

    private func context(_ source: String, permissions: Set<PluginCapability>) async throws -> String {
        let m = manifest(permissions: [.fsRead], roots: [PluginFSRoot(id: "s", path: "~/.sessions", summary: [:])])
        let package = PluginPackage(manifest: m, directory: root, source: source, origin: .builtin)
        let runtime = PluginRuntime(package: package, timeout: 2, permissions: permissions,
                                    fileReader: PluginFileReader(roots: m.fsRoots ?? [], home: home))
        let ctx = PluginRenderContext(bundleID: "com.example.app", pid: 1, appName: "App", windowID: 0, titleSummary: "")
        let slots = try await runtime.render(context: ctx).get()
        guard case .text(let text, _, _) = slots[0].node else { XCTFail("expected text"); return "" }
        return text
    }

    func testPluginReadsThroughCtxFsOnlyWithThePermission() async throws {
        let script = """
        globalThis.__switchlyPlugin = { async render(ctx) {
          if (!ctx.fs) return [{ slot: "center", node: { type: "text", value: "no-fs" } }];
          const names = (await ctx.fs.list("s", "")).map(e => e.name).join(",");
          const body = await ctx.fs.readText("s", "a.txt");
          let denied = "none"; try { await ctx.fs.readText("s", "../x"); } catch (e) { denied = String(e); }
          return [{ slot: "center", node: { type: "text", value: names + "|" + body + "|" + denied } }];
        } };
        """
        let allowed = try await context(script, permissions: [.fsRead])
        XCTAssertEqual(allowed, "a.txt,nested|hello|denied")
        let withheld = try await context(script, permissions: [])
        XCTAssertEqual(withheld, "no-fs")
    }

    func testRuntimeInjectsTheReaderProtocolAndResetsItPerInvocation() async throws {
        let m = manifest(permissions: [.fsRead], roots: [PluginFSRoot(id: "s", path: "~/.sessions", summary: [:])])
        let source = """
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            const names = (await ctx.fs.list("s", "")).map(e => e.name).join(",");
            const body = await ctx.fs.readText("s", "fixture.txt");
            const available = ctx.capabilities["fs.read"].available;
            return [{ slot: "center", node: { type: "text", value: names + "|" + body + "|" + available } }];
          },
          onAction(ctx, id, value) {}
        };
        """
        let package = PluginPackage(manifest: m, directory: root, source: source, origin: .builtin)
        let reader = ProtocolFileReader()
        let runtime = PluginRuntime(package: package, timeout: 2, permissions: [.fsRead], fileReader: reader)

        let ctx = PluginRenderContext(bundleID: "com.example.app", pid: 1, appName: "App", windowID: 0, titleSummary: "")
        let slots = try await runtime.render(context: ctx).get()
        guard case .text(let text, _, _) = slots[0].node else { return XCTFail("expected text") }
        XCTAssertEqual(text, "fixture.txt|synthetic|true")
        XCTAssertEqual(reader.resetCount, 1)

        _ = try await runtime.performAction(id: "noop", value: nil, context: ctx).get()
        XCTAssertEqual(reader.resetCount, 2, "each render/action starts a fresh fs quota")
    }

    /// `Tools/PluginPreview` is not part of the current test target. Compile the real fixture provider
    /// with the host protocol and run its contract in a temporary directory, without touching user files.
    func testSyntheticFileReaderContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-fixture-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.currentDirectoryURL = repositoryRoot
        process.arguments = [
            "swiftc", "-swift-version", "5", "-D", "PLUGIN_FIXTURE_SMOKE",
            "Models/Plugins/PluginManifest.swift",
            "Services/Plugins/PluginFileReader.swift",
            "Tools/PluginPreview/Fixtures/PluginFixtureFileReader.swift",
            "Tools/PluginPreview/Fixtures/PluginFixtureFileReaderSmoke.swift",
            "-o", temporary.appendingPathComponent("fixture-fs-smoke").path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errors)

        let marker = temporary.appendingPathComponent("result.txt")
        let smoke = Process()
        smoke.executableURL = temporary.appendingPathComponent("fixture-fs-smoke")
        smoke.arguments = [marker.path]
        try smoke.run()
        smoke.waitUntilExit()
        XCTAssertEqual(smoke.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "plugin-fixture-fs-smoke=passed\n")
    }
}

private final class ProtocolFileReader: PluginFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var resets = 0

    var resetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resets
    }

    func resetCalls() {
        lock.lock()
        resets += 1
        lock.unlock()
    }

    func list(root: String, path: String) throws -> [PluginFSEntry] {
        [PluginFSEntry(name: "fixture.txt", isDirectory: false, size: 9, modified: 1)]
    }

    func stat(root: String, path: String) throws -> PluginFSEntry {
        PluginFSEntry(name: "fixture.txt", isDirectory: false, size: 9, modified: 1)
    }

    func readText(root: String, path: String, maxBytes: Int?) throws -> String { "synthetic" }

    func scan(root: String, path: String, depth: Int, suffix: String?, modifiedWithin: TimeInterval?) throws -> [PluginFSScanEntry] { [] }

    func isLocked(root: String, path: String) throws -> Bool { false }
}
