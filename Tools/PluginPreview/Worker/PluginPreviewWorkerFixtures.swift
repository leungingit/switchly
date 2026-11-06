import Foundation

enum PluginPreviewWorkerFailure: Error, Equatable {
    case invalidRequest
    case staleGeneration
    case invalidScenario
    case invalidPackage
    case invalidGrants
    case invalidSettings
    case invalidFixture
    case notLoaded
    case suspended
    case disabled
    case timedOut
    case pluginError
    case invalidOutput
    case unsupported

    var code: String {
        switch self {
        case .invalidRequest: return "invalidRequest"
        case .staleGeneration: return "staleGeneration"
        case .invalidScenario: return "invalidScenario"
        case .invalidPackage: return "invalidPackage"
        case .invalidGrants: return "invalidGrants"
        case .invalidSettings: return "invalidSettings"
        case .invalidFixture: return "invalidFixture"
        case .notLoaded: return "notLoaded"
        case .suspended: return "suspended"
        case .disabled: return "disabled"
        case .timedOut: return "timedOut"
        case .pluginError: return "pluginError"
        case .invalidOutput: return "invalidOutput"
        case .unsupported: return "unsupported"
        }
    }

    var message: String {
        switch self {
        case .invalidRequest: return "request payload is invalid"
        case .staleGeneration: return "request generation is not active"
        case .invalidScenario: return "scenario is invalid"
        case .invalidPackage: return "plugin package is invalid"
        case .invalidGrants: return "scenario grants are invalid"
        case .invalidSettings: return "scenario settings are invalid"
        case .invalidFixture: return "preview fixture is invalid"
        case .notLoaded: return "plugin is not loaded"
        case .suspended: return "plugin is suspended"
        case .disabled: return "plugin is disabled"
        case .timedOut: return "plugin call timed out"
        case .pluginError: return "plugin script failed"
        case .invalidOutput: return "plugin render output is invalid"
        case .unsupported: return "operation is not supported"
        }
    }
}

extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let values): return values.mapValues(\.foundationValue)
        }
    }

    var settingValue: PluginSettingValue? {
        switch self {
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        default: return nil
        }
    }
}

/// JSON-only storage with the same byte budgets as the host store, but no disk
/// path and no Application Support access.
final class PluginPreviewFixtureStorage: PluginStorageProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(seed: [String: JSONValue] = [:]) throws {
        values = [:]
        for (key, value) in seed {
            let object = value.foundationValue
            try Self.validate(key: key, value: object)
            values[key] = object
        }
        guard try Self.encoded(values).count <= PluginStorage.maxTotalBytes else { throw PluginPreviewWorkerFailure.invalidFixture }
    }

    func get(_ key: String) throws -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, value: Any) throws {
        try Self.validate(key: key, value: value)
        lock.lock()
        defer { lock.unlock() }
        var next = values
        next[key] = value
        guard try Self.encoded(next).count <= PluginStorage.maxTotalBytes else { throw PluginStorage.Failure.quotaExceeded }
        values = next
    }

    func remove(_ key: String) throws {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }

    var snapshot: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    private static func validate(key: String, value: Any) throws {
        guard !key.isEmpty, key.utf8.count <= 256 else { throw PluginStorage.Failure.invalidKey }
        guard try encoded(value).count <= PluginStorage.maxValueBytes else { throw PluginStorage.Failure.quotaExceeded }
    }

    private static func encoded(_ value: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        } catch {
            throw PluginStorage.Failure.invalidData
        }
    }
}

struct PluginPreviewMediaFixture: Decodable {
    static let maxLibraryTracks = 1000
    static let maxTextBytes = 16 * 1024
    static let maxArtworkBytes = 8 * 1024 * 1024

    struct Snapshot: Decodable {
        let playing: Bool
        let title: String
        let artist: String
        let album: String
        let position: Double
        let duration: Double
        let progress: Double
        let liked: Bool
        let canLike: Bool
    }

    struct Track: Decodable {
        let persistentID: String
        let title: String
        let artist: String
        let bpm: Double
        let genres: [String]?
    }

    let nowPlaying: Snapshot?
    let library: [Track]?
    let artworkBase64: String?

    func validated() throws -> PluginPreviewMediaFixture {
        guard (library ?? []).count <= Self.maxLibraryTracks else { throw PluginPreviewWorkerFailure.invalidFixture }
        if let nowPlaying {
            let expectedProgress = nowPlaying.duration > 0 ? min(max(nowPlaying.position / nowPlaying.duration, 0), 1) : 0
            guard nowPlaying.position.isFinite, nowPlaying.duration.isFinite, nowPlaying.progress.isFinite,
                  abs(nowPlaying.progress - expectedProgress) <= 1e-9,
                  nowPlaying.position >= 0, nowPlaying.duration >= 0,
                  Self.textFits(nowPlaying.title), Self.textFits(nowPlaying.artist),
                  Self.textFits(nowPlaying.album) else {
                throw PluginPreviewWorkerFailure.invalidFixture
            }
        }
        for track in library ?? [] {
            guard !track.persistentID.isEmpty, !track.title.isEmpty, !track.artist.isEmpty,
                  track.bpm.isFinite, track.bpm >= 0,
                  Self.textFits(track.persistentID), Self.textFits(track.title), Self.textFits(track.artist),
                  (track.genres ?? []).count <= 32,
                  (track.genres ?? []).allSatisfy({ !$0.isEmpty && Self.textFits($0) }) else {
                throw PluginPreviewWorkerFailure.invalidFixture
            }
        }
        if let artworkBase64 {
            guard artworkBase64.utf8.count <= Self.maxArtworkBytes * 2,
                  let data = Data(base64Encoded: artworkBase64),
                  data.count <= Self.maxArtworkBytes else {
                throw PluginPreviewWorkerFailure.invalidFixture
            }
        }
        return self
    }

    private static func textFits(_ value: String) -> Bool {
        value.utf8.count <= maxTextBytes
    }
}

final class PluginPreviewMediaBridge: MediaBridging, MusicLibraryPlaying, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.switchly.preview.fixture-media")
    private let lock = NSLock()
    private let tracks: [PluginPreviewMediaFixture.Track]
    private let artworkData: Data?
    private var current: NowPlaying?

    init(fixture: PluginPreviewMediaFixture) {
        tracks = fixture.library ?? []
        artworkData = fixture.artworkBase64.flatMap { Data(base64Encoded: $0) }
        current = fixture.nowPlaying.map {
            NowPlaying(isPlaying: $0.playing, title: $0.title, artist: $0.artist, album: $0.album,
                       position: $0.position, duration: $0.duration, liked: $0.liked, canLike: $0.canLike)
        }
    }

    func supports(bundleID: String) -> Bool { true }

    func nowPlaying(bundleID: String) throws -> NowPlaying? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func perform(_ command: MediaCommand, bundleID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        switch command {
        case .togglePlayPause:
            guard let now = current else { return }
            current = copy(now, playing: !now.isPlaying)
        case .next:
            moveTrack(offset: 1)
        case .previous:
            moveTrack(offset: -1)
        case .like, .unlike:
            guard let now = current, now.canLike else { return }
            current = copy(now, liked: command == .like)
        }
    }

    func artwork(bundleID: String) throws -> Data? { artworkData }

    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
        let words = genreKeywords.map { $0.lowercased() }
        let match = tracks.first { track in
            (track.genres ?? []).contains { genre in words.contains { genre.lowercased().contains($0) } }
        }
        guard let track = match ?? tracks.first else { return nil }
        return PickedTrack(persistentID: track.persistentID, title: track.title, artist: track.artist,
                           bpm: track.bpm, matchedGenre: match != nil)
    }

    func play(persistentID: String) throws {
        guard let track = tracks.first(where: { $0.persistentID == persistentID }) else {
            throw MediaBridgeError.unsupportedApp
        }
        lock.lock()
        current = playing(track)
        lock.unlock()
    }

    func pausePlayback() throws {
        lock.lock()
        if let now = current { current = copy(now, playing: false) }
        lock.unlock()
    }

    func currentTrack() throws -> NowPlaying? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func moveTrack(offset: Int) {
        guard !tracks.isEmpty else { return }
        let currentID = current?.title
        let index = tracks.firstIndex { $0.title == currentID }.map { ($0 + offset + tracks.count) % tracks.count } ?? 0
        current = playing(tracks[index])
    }

    private func playing(_ track: PluginPreviewMediaFixture.Track) -> NowPlaying {
        NowPlaying(isPlaying: true, title: track.title, artist: track.artist, album: "",
                   position: 0, duration: 180, liked: current?.liked ?? false, canLike: true)
    }

    private func copy(_ now: NowPlaying, playing: Bool? = nil, liked: Bool? = nil) -> NowPlaying {
        NowPlaying(isPlaying: playing ?? now.isPlaying, title: now.title, artist: now.artist, album: now.album,
                   position: now.position, duration: now.duration, liked: liked ?? now.liked, canLike: now.canLike)
    }
}

struct PluginPreviewWeatherFixture: Decodable {
    static let maxConditionBytes = 64

    let condition: String
    let temperature: Double
    let wind: Double
    let source: String

    func validated() throws -> PluginPreviewWeatherFixture {
        guard !condition.isEmpty, condition.utf8.count <= Self.maxConditionBytes,
              temperature.isFinite, wind.isFinite, wind >= 0, source == "online" else {
            throw PluginPreviewWorkerFailure.invalidFixture
        }
        return self
    }

    var jsObject: [String: Any] {
        ["condition": condition, "temperature": temperature, "wind": wind, "source": source]
    }
}

struct PluginPreviewResolvedSettings {
    let toggles: [String: Bool]
    let values: [String: PluginSettingValue]
}

struct PluginPreviewLoadedFixtures {
    let media: PluginPreviewMediaFixture?
    let weather: PluginPreviewWeatherFixture?
    let fs: PluginFixtureFileReader?
    let storage: PluginPreviewFixtureStorage
    let sources: [String: String]
}

struct PluginPreviewPreparedPlugin {
    let runtime: PluginRuntime
    let context: PluginRenderContext
    let pluginID: String
    let permissions: [String]
    let fixtureSources: [String: String]
    let artworkBase64: String?
    let storage: PluginPreviewFixtureStorage
    let hasVirtualClock: Bool
}

enum PluginPreviewWorkerLoader {
    static let maxScenarioBytes = 1024 * 1024

    static func load(pluginDirectory: String, scenarioPath: String, storageJSON: String? = nil) throws -> PluginPreviewPreparedPlugin {
        let pluginURL = try explicitURL(pluginDirectory, expectingDirectory: true)
        let scenarioURL = try explicitURL(scenarioPath, expectingDirectory: false)
        let scenarioData: Data
        do {
            scenarioData = try PreviewFixtureFile.read(
                relativePath: scenarioURL.lastPathComponent,
                scenarioDirectory: scenarioURL.deletingLastPathComponent(),
                maximumBytes: maxScenarioBytes
            )
        } catch {
            throw PluginPreviewWorkerFailure.invalidScenario
        }
        let scenario: PreviewScenario
        do {
            scenario = try PreviewScenario.decode(scenarioData)
        } catch PreviewScenario.Failure.unsupportedSteps {
            throw PluginPreviewWorkerFailure.unsupported
        } catch {
            throw PluginPreviewWorkerFailure.invalidScenario
        }
        guard scenario.schemaVersion == 1 else { throw PluginPreviewWorkerFailure.invalidScenario }

        let package: PluginPackage
        do {
            package = try PluginPackageValidator.load(directory: pluginURL, origin: .user)
        } catch {
            throw PluginPreviewWorkerFailure.invalidPackage
        }

        let grants = try resolveGrants(scenario: scenario)
        let authorization = PluginAuthorization.resolve(
            manifest: package.manifest,
            origin: .user,
            grant: PluginGrant(isEnabled: true, permissions: grants)
        )
        let settings = try resolveSettings(scenario: scenario, manifest: package.manifest)
        let fixtures = try loadFixtures(scenario: scenario, scenarioDirectory: scenarioURL.deletingLastPathComponent(), storageJSON: storageJSON)

        if let fs = fixtures.fs, let roots = package.manifest.fsRoots {
            guard Set(roots.map(\.id)).isSubset(of: fs.rootIDs) else {
                throw PluginPreviewWorkerFailure.invalidFixture
            }
        }

        let mediaBridge = fixtures.media.map(PluginPreviewMediaBridge.init(fixture:))
        let weather = fixtures.weather
        let virtualClock = scenario.clock.map {
            PluginVirtualClock(startMilliseconds: $0.startEpochMs, seed: $0.seed)
        }
        let runtime = PluginRuntime(
            package: package,
            timeout: 2,
            preferredLanguages: [scenario.environment.locale],
            mediaBridge: mediaBridge,
            permissions: authorization.permissions,
            libraryBridge: mediaBridge,
            fileReader: fixtures.fs,
            settings: { settings.toggles },
            values: { settings.values },
            weather: weather.map { fixture in { fixture.jsObject } },
            storage: fixtures.storage,
            virtualClock: virtualClock,
            reduceMotion: { scenario.environment.reduceMotion }
        )
        let context = PluginRenderContext(
            bundleID: scenario.target.bundleID,
            pid: 0,
            appName: scenario.target.appName,
            windowID: 0,
            titleSummary: PluginRenderContext.summarize(title: scenario.target.titleSummary ?? ""),
            lastActiveAt: scenario.target.lastActiveAt
        )
        return PluginPreviewPreparedPlugin(
            runtime: runtime,
            context: context,
            pluginID: package.manifest.id,
            permissions: authorization.permissions.map(\.rawValue).sorted(),
            fixtureSources: fixtures.sources,
            artworkBase64: authorization.permissions.contains(.mediaNowPlaying) ? fixtures.media?.artworkBase64 : nil,
            storage: fixtures.storage,
            hasVirtualClock: virtualClock != nil
        )
    }

    private static func explicitURL(_ path: String, expectingDirectory: Bool) throws -> URL {
        let failure: PluginPreviewWorkerFailure = expectingDirectory ? .invalidPackage : .invalidScenario
        guard path.hasPrefix("/"), !path.contains("\0") else { throw failure }
        let original = URL(fileURLWithPath: path)
        let values = try? original.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isSymbolicLink != true,
              expectingDirectory ? values?.isDirectory == true : values?.isRegularFile == true else {
            throw failure
        }
        if !expectingDirectory {
            guard (values?.fileSize ?? 0) <= maxScenarioBytes else { throw failure }
        }
        return original.resolvingSymlinksInPath()
    }

    private static func resolveGrants(scenario: PreviewScenario) throws -> [String] {
        let grants = scenario.grants ?? []
        guard grants.allSatisfy({ PluginCapability(rawValue: $0) != nil }) else {
            throw PluginPreviewWorkerFailure.invalidGrants
        }
        return grants
    }

    private static func resolveSettings(scenario: PreviewScenario, manifest: PluginManifest) throws -> PluginPreviewResolvedSettings {
        let specs = Dictionary(uniqueKeysWithValues: (manifest.settings ?? []).map { ($0.key, $0) })
        var toggles: [String: Bool] = [:]
        var values: [String: PluginSettingValue] = [:]
        for (key, raw) in scenario.settings ?? [:] {
            guard let spec = specs[key], let value = raw.settingValue else {
                throw PluginPreviewWorkerFailure.invalidSettings
            }
            switch (spec.kind, value) {
            case (.toggle, .bool(let enabled)):
                toggles[key] = enabled
            case (.select, .string(let selected)) where spec.options.contains(where: { $0.value == selected }):
                values[key] = .string(selected)
            case (.number, .number(let number)):
                guard number.isFinite,
                      (spec.min ?? -.infinity) <= number,
                      number <= (spec.max ?? .infinity) else {
                    throw PluginPreviewWorkerFailure.invalidSettings
                }
                values[key] = .number(number)
            default:
                throw PluginPreviewWorkerFailure.invalidSettings
            }
        }
        return PluginPreviewResolvedSettings(toggles: toggles, values: values)
    }

    private static func loadFixtures(scenario: PreviewScenario, scenarioDirectory: URL, storageJSON: String?) throws -> PluginPreviewLoadedFixtures {
        var sources: [String: String] = ["storage": "memory"]
        let media: PluginPreviewMediaFixture?
        if let path = scenario.fixtures?.media {
            let data = try fixtureData(path, scenarioDirectory: scenarioDirectory)
            try validateMediaShape(data)
            do { media = try JSONDecoder().decode(PluginPreviewMediaFixture.self, from: data).validated() }
            catch { throw PluginPreviewWorkerFailure.invalidFixture }
            sources["media"] = "fixture"
        } else {
            media = nil
        }

        let weather: PluginPreviewWeatherFixture?
        if let path = scenario.fixtures?.weather {
            let data = try fixtureData(path, scenarioDirectory: scenarioDirectory)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  Set(object.keys) == Set(["condition", "temperature", "wind", "source"]) else {
                throw PluginPreviewWorkerFailure.invalidFixture
            }
            do { weather = try JSONDecoder().decode(PluginPreviewWeatherFixture.self, from: data).validated() }
            catch { throw PluginPreviewWorkerFailure.invalidFixture }
            sources["weather"] = "fixture"
        } else {
            weather = nil
        }

        let fs: PluginFixtureFileReader?
        if let path = scenario.fixtures?.fs {
            let data = try fixtureData(path, scenarioDirectory: scenarioDirectory)
            do { fs = try PluginFixtureFileReader.decode(data) }
            catch { throw PluginPreviewWorkerFailure.invalidFixture }
            sources["fs"] = "fixture"
        } else {
            fs = nil
        }

        let storage: PluginPreviewFixtureStorage
        do {
            let seed: [String: JSONValue]
            if let storageJSON {
                let data = Data(storageJSON.utf8)
                guard data.count <= PluginStorage.maxTotalBytes else { throw PluginPreviewWorkerFailure.invalidFixture }
                seed = try JSONDecoder().decode([String: JSONValue].self, from: data)
            } else { seed = scenario.storageSeed ?? [:] }
            storage = try PluginPreviewFixtureStorage(seed: seed)
        } catch {
            throw PluginPreviewWorkerFailure.invalidFixture
        }
        return PluginPreviewLoadedFixtures(media: media, weather: weather, fs: fs, storage: storage, sources: sources)
    }

    private static func fixtureData(_ path: String, scenarioDirectory: URL) throws -> Data {
        do {
            return try PreviewFixtureFile.read(
                relativePath: path,
                scenarioDirectory: scenarioDirectory,
                maximumBytes: PluginPackageValidator.maxPackageBytes
            )
        } catch {
            throw PluginPreviewWorkerFailure.invalidFixture
        }
    }

    private static func validateMediaShape(_ data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: ["nowPlaying", "library", "artworkBase64"]) else {
            throw PluginPreviewWorkerFailure.invalidFixture
        }
        if let playing = object["nowPlaying"], !(playing is NSNull) {
            guard let snapshot = playing as? [String: Any],
                  Set(snapshot.keys) == Set(["playing", "title", "artist", "album", "position", "duration", "progress", "liked", "canLike"]) else {
                throw PluginPreviewWorkerFailure.invalidFixture
            }
        }
        if let library = object["library"] {
            guard let tracks = library as? [[String: Any]], tracks.allSatisfy({
                Set($0.keys).isSubset(of: ["persistentID", "title", "artist", "bpm", "genres"]) && !($0["genres"] is NSNull)
            }) else { throw PluginPreviewWorkerFailure.invalidFixture }
        }
        if object["artworkBase64"] is NSNull { throw PluginPreviewWorkerFailure.invalidFixture }
    }
}
