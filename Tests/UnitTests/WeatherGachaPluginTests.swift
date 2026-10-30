import JavaScriptCore
import XCTest
@testable import Switchly

private final class FakeNowPlaying: MediaBridging, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.gacha.media")
    var current: NowPlaying?
    func supports(bundleID: String) -> Bool { bundleID == "com.apple.Music" }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { current }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
    func artwork(bundleID: String) throws -> Data? { nil }
}

private final class FakeLibrary: MusicLibraryPlaying, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.gacha.library")
    var track: PickedTrack? = PickedTrack(persistentID: "ABC123", title: "Song", artist: "Artist", bpm: 120, matchedGenre: true)
    var pickError: Error?
    private(set) var picked: [[String]] = []
    private(set) var played: [String] = []
    private(set) var pauses = 0

    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
        picked.append(genreKeywords)
        if let pickError { throw pickError }
        return track
    }
    func play(persistentID: String) throws { played.append(persistentID) }
    func pausePlayback() throws { pauses += 1 }
    func currentTrack() throws -> NowPlaying? { nil }
}

final class WeatherGachaPluginTests: XCTestCase {
    private let context = PluginRenderContext(bundleID: "com.apple.Music", pid: 1, appName: "Music", windowID: 0, titleSummary: "")

    private var package: PluginPackage {
        get throws {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Plugins").standardizedFileURL
            let result = PluginRegistry(directory: dir, origin: .builtin).reload()
            XCTAssertEqual(result.failures, [])
            return try XCTUnwrap(result.plugins.first { $0.manifest.id == "com.switchly.weather-gacha" })
        }
    }

    private func makeRuntime(library: FakeLibrary = FakeLibrary(), media: FakeNowPlaying = FakeNowPlaying(), reduceMotion: Bool = true,
                             values: [String: PluginSettingValue] = [:]) throws -> PluginRuntime {
        let pkg = try package
        return PluginRuntime(package: pkg, timeout: 2, preferredLanguages: ["en"], mediaBridge: media,
                             permissions: Set(pkg.manifest.permissions), libraryBridge: library,
                             values: { values }, reduceMotion: { reduceMotion })
    }

    // MARK: Engine (JS)

    private func engine() throws -> JSContext {
        let js = try XCTUnwrap(JSContext())
        js.exceptionHandler = { _, e in XCTFail("JS: \(e?.toString() ?? "?")") }
        js.evaluateScript("globalThis.setTimeout = function () { return 1; }; globalThis.clearTimeout = function () {};")
        js.evaluateScript(try package.source)
        js.evaluateScript("""
        globalThis.seeded = function (seed) { let s = seed; return function () { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296; }; };
        globalThis.sky = { condition: "rain", temperature: 15, wind: 5, season: "autumn" };
        """)
        return js
    }

    func testDrawDealsOneCardPerKindAndIsDeterministic() throws {
        let js = try engine()
        let kinds = js.evaluateScript("JSON.stringify(__switchlyPlugin.__test.draw(sky, 0, seeded(7)).cards.map(function (c) { return c.kind; }))")?.toString()
        XCTAssertEqual(kinds, #"["mood","genre","scene"]"#)
        let a = js.evaluateScript("JSON.stringify(__switchlyPlugin.__test.draw(sky, 0, seeded(42)))")?.toString()
        let b = js.evaluateScript("JSON.stringify(__switchlyPlugin.__test.draw(sky, 0, seeded(42)))")?.toString()
        XCTAssertEqual(a, b)
    }

    func testPityGuaranteesARareAfterThresholdAndCountsUpBefore() throws {
        let js = try engine()
        // rng 0.99 rolls common for every kind.
        js.evaluateScript("globalThis.low = function () { return 0.99; };")
        let before = js.evaluateScript("JSON.stringify(__switchlyPlugin.__test.draw(sky, 3, low))")?.toString() ?? ""
        XCTAssertTrue(before.hasSuffix(#""pity":4}"#), before)
        let at = js.evaluateScript("var r = __switchlyPlugin.__test.draw(sky, 9, low); r.cards.some(function (c) { return c.rarity >= 1; }) && r.pity === 0")?.toBool()
        XCTAssertEqual(at, true)
        let epic = js.evaluateScript("var r = __switchlyPlugin.__test.draw(sky, 5, function () { return 0; }); r.pity === 0 && r.cards.every(function (c) { return c.rarity === 2; })")?.toBool()
        XCTAssertEqual(epic, true, "roll 0 is epic for every kind and resets pity")
    }

    func testOffWeatherCardsStayPossibleButRare() throws {
        let js = try engine()
        // Snowfall (epic scene) needs snow; with rain it only has the off-weather weight, yet an epic roll still lands on an epic scene.
        let id = js.evaluateScript("__switchlyPlugin.__test.draw(sky, 0, function () { return 0; }).cards[2].id")?.toString()
        XCTAssertTrue(["scene.snowfall", "scene.windRider"].contains(id ?? ""), id ?? "nil")
    }

    func testSeasonFollowsHemisphere() throws {
        let js = try engine()
        let season = { (south: Bool, month: Int) -> String in
            js.evaluateScript("__switchlyPlugin.__test.weatherOf({southernHemisphere: \(south)}, new Date(2026, \(month), 15)).season")?.toString() ?? ""
        }
        XCTAssertEqual(season(false, 9), "autumn")
        XCTAssertEqual(season(true, 9), "spring")
        XCTAssertEqual(season(false, 0), "winter")
        XCTAssertEqual(season(true, 6), "winter")
    }

    func testEveryCardHasATheme() throws {
        let js = try engine()
        XCTAssertEqual(js.evaluateScript("__switchlyPlugin.__test.POOL.length")?.toInt32(), 18)
        let missing = js.evaluateScript("__switchlyPlugin.__test.POOL.map(function (p) { return p.card.id; }).filter(function (id) { return !__switchlyPlugin.__test.THEMES[id]; }).join(',')")?.toString()
        XCTAssertEqual(missing, "")
    }

    // MARK: Flow

    private func scene(in slots: [PluginSlotContent], key prefix: String? = nil) -> PluginScene? {
        func scenes(_ node: PluginUINode) -> [PluginScene] {
            if case .scene(let s) = node { return [s] }
            return node.children.flatMap(scenes)
        }
        return slots.flatMap { scenes($0.node) }.last { $0.fit == .width && (prefix.map($0.key.hasSuffix) ?? true) }
    }

    private func waitForHit(_ id: String, runtime: PluginRuntime, seconds: Double = 3) async throws -> [PluginSlotContent] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let slots = try await runtime.render(context: context).get()
            if slots.flatMap({ $0.node.actionIDs }).contains(id) { return slots }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("hit \(id) never appeared")
        return []
    }

    func testFirstRenderIsAValidSceneCardWithCardsAndInfoHits() async throws {
        let runtime = try makeRuntime()
        let slots = try await runtime.render(context: context).get()
        XCTAssertEqual(slots.map(\.slot), [.center])
        let ids = slots.flatMap { $0.node.actionIDs }
        XCTAssertEqual(ids.filter { $0.hasPrefix("pick:") }.count, 3)
        XCTAssertEqual(ids.filter { $0.hasPrefix("info:") }.count, 4)
        let main = try XCTUnwrap(scene(in: slots))
        XCTAssertEqual(main.hits.count, ids.count)
        XCTAssertLessThanOrEqual(main.layers.reduce(0) { $0 + $1.layerCount }, PluginScene.maxLayers)
    }

    func testPickRevealPlayAndFinishFlow() async throws {
        let library = FakeLibrary()
        let media = FakeNowPlaying()
        media.current = NowPlaying(isPlaying: true, title: "Song", artist: "Artist", album: "", position: 5, duration: 200, liked: false, canLike: true)
        let runtime = try makeRuntime(library: library, media: media)
        var slots = try await runtime.render(context: context).get()
        let pick = try XCTUnwrap(slots.flatMap { $0.node.actionIDs }.first { $0.hasPrefix("pick:") })

        _ = await runtime.performAction(id: pick, value: nil, context: context)
        slots = try await waitForHit("play", runtime: runtime)
        XCTAssertEqual(library.picked.count, 1)
        XCTAssertFalse(library.picked[0].isEmpty, "the card's genre keywords reach the library")

        _ = await runtime.performAction(id: "play", value: nil, context: context)
        slots = try await waitForHit("again", runtime: runtime)
        XCTAssertEqual(library.played, ["ABC123"])
        XCTAssertFalse(slots.flatMap { $0.node.actionIDs }.contains("play"), "no Play button while the song plays")

        // The song ends: Music moves on to another track, the round finishes and Music is paused.
        media.current = NowPlaying(isPlaying: true, title: "Next", artist: "Other", album: "", position: 0, duration: 200, liked: false, canLike: true)
        let end = Date().addingTimeInterval(3)
        while library.pauses == 0, Date() < end { _ = try await runtime.render(context: context).get(); try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(library.pauses, 1)
    }

    func testAgainDuringPlaybackPausesAndDealsNewCards() async throws {
        let library = FakeLibrary()
        let media = FakeNowPlaying()
        media.current = NowPlaying(isPlaying: true, title: "Song", artist: "Artist", album: "", position: 5, duration: 200, liked: false, canLike: true)
        let runtime = try makeRuntime(library: library, media: media)
        let first = try await runtime.render(context: context).get()
        let firstScene = try XCTUnwrap(scene(in: first))
        let pick = try XCTUnwrap(first.flatMap { $0.node.actionIDs }.first { $0.hasPrefix("pick:") })
        _ = await runtime.performAction(id: pick, value: nil, context: context)
        _ = try await waitForHit("play", runtime: runtime)
        _ = await runtime.performAction(id: "play", value: nil, context: context)
        _ = try await waitForHit("again", runtime: runtime)

        _ = await runtime.performAction(id: "again", value: nil, context: context)
        let slots = try await waitForHit(pick.hasPrefix("pick:") ? "info:wind" : "", runtime: runtime)
        let next = try XCTUnwrap(scene(in: slots))
        XCTAssertNotEqual(next.key, firstScene.key, "a new round gets a new scene")
        XCTAssertGreaterThanOrEqual(library.pauses, 1, "interrupting a song pauses it")
        XCTAssertEqual(slots.flatMap { $0.node.actionIDs }.filter { $0.hasPrefix("pick:") }.count, 3)
    }

    func testLibraryFailuresShowAnAgainButton() async throws {
        let library = FakeLibrary()
        library.pickError = MediaBridgeError.notAuthorized
        let runtime = try makeRuntime(library: library)
        let first = try await runtime.render(context: context).get()
        let pick = try XCTUnwrap(first.flatMap { $0.node.actionIDs }.first { $0.hasPrefix("pick:") })
        _ = await runtime.performAction(id: pick, value: nil, context: context)
        let slots = try await waitForHit("again", runtime: runtime)
        let texts = try XCTUnwrap(scene(in: slots)).layers.compactMap(\.text)
        XCTAssertTrue(texts.contains("Allow Switchly to control Music, then draw again."), "\(texts)")
    }

    func testSettingsReachThePluginAndShapeTheHeader() async throws {
        let runtime = try makeRuntime(values: ["condition": .string("storm"), "temperature": .number(31.4)])
        let slots = try await runtime.render(context: context).get()
        let main = try XCTUnwrap(scene(in: slots))
        let labels = main.layers.compactMap(\.hit?.label)
        XCTAssertTrue(labels.contains("Storm"), "\(labels)")
        XCTAssertTrue(labels.contains("31 °C"), "\(labels)")
    }

    func testLibraryOnlyPermissionStillExposesCtxMediaLibrary() async throws {
        // A scene plugin that only plays songs has no nowPlaying bridge at all.
        let pkg = try package
        let library = FakeLibrary()
        let runtime = PluginRuntime(package: pkg, timeout: 2, permissions: [.mediaLibrary], libraryBridge: library, reduceMotion: { true })
        let slots = try await runtime.render(context: context).get()
        let pick = try XCTUnwrap(slots.flatMap { $0.node.actionIDs }.first { $0.hasPrefix("pick:") })
        _ = await runtime.performAction(id: pick, value: nil, context: context)
        let end = Date().addingTimeInterval(2)
        while library.picked.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(library.picked.count, 1)
    }

    func testPluginWithoutLibraryPermissionCannotReachTheLibrary() async throws {
        let pkg = try package
        let library = FakeLibrary()
        let runtime = PluginRuntime(package: pkg, timeout: 2, mediaBridge: FakeNowPlaying(), permissions: [.mediaNowPlaying],
                                    libraryBridge: library, reduceMotion: { true })
        let first = try await runtime.render(context: context).get()
        let pick = try XCTUnwrap(first.flatMap { $0.node.actionIDs }.first { $0.hasPrefix("pick:") })
        _ = await runtime.performAction(id: pick, value: nil, context: context)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(library.picked.count, 0)
    }
}
