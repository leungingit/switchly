import Foundation

enum DefaultScenarioTests {
    static func run() throws {
        let manifest = try makeManifest()
        try deriveRules(manifest)
        try builtinRules(manifest)
        try fixtureSourceRules(manifest)
        try overrideRules(manifest)
        try roundTrip(manifest)
        try fixtureTransfer(manifest)
        try exporter(manifest)
        try builtinExporter(manifest)
        try commandLine()
        try inspectReport(manifest)
        try missingFixtureReporting(manifest)
        print("默认场景、覆盖项与 inspect 测试通过")
    }

    private static func makeManifest(
        permissions: [String] = ["media.nowPlaying", "weather.current"],
        fsRoots: [[String: Any]]? = nil
    ) throws -> PluginManifest {
        var object: [String: Any] = [
            "id": "com.example.preview",
            "name": ["en": "Preview Fixture"],
            "version": "1.0.0",
            "apiVersion": 2,
            "matches": ["com.example.app", "com.example.other"],
            "permissions": permissions,
            "entry": "main.js",
            "settings": [
                ["key": "showArtwork", "title": ["en": "Show artwork"], "default": true],
                ["key": "layout", "title": ["en": "Layout"], "default": "compact", "type": "select",
                 "options": [["value": "compact", "title": ["en": "Compact"]],
                             ["value": "wide", "title": ["en": "Wide"]]]],
                ["key": "cardWidth", "title": ["en": "Card width"], "default": 360,
                 "type": "number", "min": 300, "max": 720, "step": 20],
            ],
        ]
        if let fsRoots {
            object["fsRoots"] = fsRoots
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private static func fsManifest() throws -> PluginManifest {
        try makeManifest(permissions: ["fs.read"],
                         fsRoots: [["id": "sessions", "path": "~/SyntheticSessions",
                                    "summary": ["en": "Synthetic sessions"]]])
    }

    /// 契约 §2.1：媒体类权限任一启用内置媒体样例，天气同理；无权限时三者都不可用。
    private static func builtinRules(_ manifest: PluginManifest) throws {
        let mediaControl = try makeManifest(permissions: ["media.control"])
        precondition(PreviewScenarioDraft.derive(manifest: mediaControl).fixtures.media == .builtin)
        precondition(PreviewScenarioDraft.derive(manifest: mediaControl).fixtures.weather == .none)

        let weatherOnly = try makeManifest(permissions: ["weather.current"])
        precondition(PreviewScenarioDraft.derive(manifest: weatherOnly).fixtures.media == .none)
        precondition(PreviewScenarioDraft.derive(manifest: weatherOnly).fixtures.weather == .builtin)

        let noSyntheticCapability = try makeManifest(permissions: ["window.focus"])
        let noneDraft = PreviewScenarioDraft.derive(manifest: noSyntheticCapability)
        precondition(noneDraft.fixtures.isEmpty)
        precondition(noneDraft.missingRequiredFixtureKind(for: noSyntheticCapability) == nil)

        let fs = try fsManifest()
        let fsDraft = PreviewScenarioDraft.derive(manifest: fs)
        precondition(fsDraft.fixtures.isEmpty)
        precondition(fsDraft.missingRequiredFixtureKind(for: fs) == .fs)

        let activity = try makeManifest(permissions: ["activity.read", "activity.snapshots"])
        let activityDraft = PreviewScenarioDraft.derive(manifest: activity)
        precondition(activityDraft.fixtures.activity == .none)
        precondition(activityDraft.missingRequiredFixtureKind(for: activity) == .activity)

        // GUI「清除」把内置样例置为不可用，不回退。
        var cleared = PreviewScenarioDraft.derive(manifest: manifest)
        cleared.fixtures.media = .none
        precondition(cleared.missingRequiredFixtureKind(for: manifest) == .media)
        cleared.fixtures.media = .builtin
        cleared.fixtures.weather = .none
        precondition(cleared.missingRequiredFixtureKind(for: manifest) == .weather)
    }

    /// 三态来源：builtin 只存在于草稿/派生场景，explicit 与 none 经场景文件往返保持。
    private static func fixtureSourceRules(_ manifest: PluginManifest) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-fixture-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var draft = PreviewScenarioDraft.derive(manifest: manifest)
        precondition(draft.fixtures.media == .builtin)
        precondition(draft.fixtures.weather == .builtin)
        precondition(draft.fixtures.fs == .none)

        draft.fixtures.media = .explicit(URL(fileURLWithPath: "/explicit/media.json"))
        draft.fixtures.weather = .none
        let data = try draft.encode(fixtureRelativePaths: [.media: "fixtures/media.json"])
        let decoded = try PreviewScenarioDraft.decode(data, scenarioDirectory: directory)
        precondition(decoded.fixtures.media == .explicit(directory.appendingPathComponent("fixtures/media.json")))
        precondition(decoded.fixtures.weather == .none)
        precondition(decoded.fixtures.fs == .none)

        // 场景未声明 fixtures 时，显式场景语义为 none；不会自动补内置样例。
        let bare = try PreviewScenarioDraft.decode(try draft.encode(), scenarioDirectory: directory)
        precondition(bare.fixtures.media == .none && bare.fixtures.weather == .none)
    }

    private static func deriveRules(_ manifest: PluginManifest) throws {
        let draft = PreviewScenarioDraft.derive(manifest: manifest)
        precondition(draft.id == "default")
        precondition(draft.locale == .en && draft.appearance == .light)
        precondition(draft.glass == false && draft.reduceMotion == true && draft.contentWidthPoints == 360)
        precondition(draft.target == .init(bundleID: "com.example.app", appName: "App"))
        precondition(draft.grants == ["media.nowPlaying", "weather.current"])
        precondition(draft.settings.isEmpty)
        // 契约 §2.1：media/weather 自动使用内置样例；fs 没有内置样例。
        precondition(draft.fixtures.media == .builtin)
        precondition(draft.fixtures.weather == .builtin)
        precondition(draft.fixtures.fs == .none)
        precondition(draft.missingRequiredFixtureKind(for: manifest) == nil)
        precondition(draft.clock.isEnabled)
        precondition(draft.clock.startEpochMs == 1_700_000_000_000 && draft.clock.seed == 1)
        precondition(PreviewScenarioDraft.appName(for: "com.example.music-controls") == "Music-controls")

        let scenario = try PreviewScenario.decode(draft.encode())
        precondition(scenario.schemaVersion == 1 && scenario.id == "default")
        precondition(scenario.environment.contentWidthPoints == 360)
        precondition(scenario.target.bundleID == "com.example.app")
        precondition(scenario.grants == draft.grants)
        precondition(scenario.clock?.seed == 1)
        precondition(scenario.settings == nil && scenario.fixtures == nil)
        precondition(scenario.typedSteps.isEmpty)

        // 编码只写 schema 允许的字段；默认场景不写 fixtures/settings/steps。
        let object = try JSONSerialization.jsonObject(with: draft.encode()) as? [String: Any] ?? [:]
        let keys = Set(object.keys)
        precondition(!keys.contains("fixtures") && !keys.contains("settings") && !keys.contains("steps"))
        precondition(keys.isSubset(of: ["schemaVersion", "id", "environment", "target", "fixtures",
                                        "clock", "grants", "settings", "storageSeed", "steps"]))
    }

    private static func overrideRules(_ manifest: PluginManifest) throws {
        var draft = PreviewScenarioDraft.derive(manifest: manifest)
        var overrides = PreviewScenarioOverrides()
        overrides.locale = .zhHans
        overrides.appearance = .dark
        overrides.glass = true
        overrides.reduceMotion = false
        overrides.width = 320
        // fs.read 不在 manifest 中，取交集后必须被丢弃；声明过的 media.nowPlaying 保留。
        overrides.grants = ["fs.read", "media.nowPlaying"]
        overrides.settings = ["showArtwork": "false", "layout": "wide", "cardWidth": "400"]
        overrides.targetBundleID = "com.example.other"
        overrides.targetAppName = "Other"
        let fixture = URL(fileURLWithPath: "/tmp/media.json")
        overrides.fixtures = [.media: fixture]
        try draft.applyOverrides(overrides, manifest: manifest)

        precondition(draft.locale == .zhHans && draft.appearance == .dark)
        precondition(draft.glass && !draft.reduceMotion && draft.contentWidthPoints == 320)
        precondition(draft.target == .init(bundleID: "com.example.other", appName: "Other"))
        precondition(draft.grants == ["media.nowPlaying"])
        precondition(draft.settings["showArtwork"] == .bool(false))
        precondition(draft.settings["layout"] == .string("wide"))
        precondition(draft.settings["cardWidth"] == .number(400))
        precondition(draft.fixtures.media == .explicit(fixture))

        let scenario = try PreviewScenario.decode(draft.encode(fixtureRelativePaths: [.media: "fixtures/media.json"]))
        precondition(scenario.environment.locale == "zh-Hans")
        precondition(scenario.settings?["showArtwork"] != nil)
        precondition(scenario.fixtures?.media == "fixtures/media.json")

        func expect(_ overrides: PreviewScenarioOverrides, _ expected: PreviewScenarioOverrideError) {
            var draft = PreviewScenarioDraft.derive(manifest: manifest)
            do {
                try draft.applyOverrides(overrides, manifest: manifest)
                fatalError("unexpectedly accepted overrides")
            } catch let error as PreviewScenarioOverrideError {
                precondition(error == expected, "unexpected error: \(error)")
            } catch { fatalError("unexpected error: \(error)") }
        }
        var unknownSetting = PreviewScenarioOverrides(); unknownSetting.settings = ["bogus": "true"]
        expect(unknownSetting, .invalidSettings)
        var badToggle = PreviewScenarioOverrides(); badToggle.settings = ["showArtwork": "yes"]
        expect(badToggle, .invalidSettings)
        var badSelect = PreviewScenarioOverrides(); badSelect.settings = ["layout": "nope"]
        expect(badSelect, .invalidSettings)
        var badNumber = PreviewScenarioOverrides(); badNumber.settings = ["cardWidth": "100"]
        expect(badNumber, .invalidSettings)
        var unknownGrant = PreviewScenarioOverrides(); unknownGrant.grants = ["bogus.capability"]
        expect(unknownGrant, .invalidGrants)
        var badWidth = PreviewScenarioOverrides(); badWidth.width = 999
        expect(badWidth, .invalidArgument("--width must be within 300...720"))
        var emptyTarget = PreviewScenarioOverrides(); emptyTarget.targetAppName = "  "
        expect(emptyTarget, .invalidArgument("--target-app-name must not be empty"))

        // `--grants none` 是显式的空授权，而不是“未提供”。
        var none = PreviewScenarioOverrides(); none.grants = []
        var emptyDraft = PreviewScenarioDraft.derive(manifest: manifest)
        try emptyDraft.applyOverrides(none, manifest: manifest)
        precondition(emptyDraft.grants.isEmpty)
        let emptyScenario = try PreviewScenario.decode(emptyDraft.encode())
        precondition(emptyScenario.grants == [])
    }

    private static func roundTrip(_ manifest: PluginManifest) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-draft-roundtrip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("media.json"))

        var draft = PreviewScenarioDraft.derive(manifest: manifest)
        draft.clock = .init(isEnabled: false, startEpochMs: draft.clock.startEpochMs, seed: draft.clock.seed)
        draft.fixtures.media = .explicit(directory.appendingPathComponent("media.json"))
        draft.settings["layout"] = .string("wide")

        let encoded = try draft.encode(fixtureRelativePaths: [.media: "media.json"])
        let decoded = try PreviewScenarioDraft.decode(encoded, scenarioDirectory: directory)
        precondition(decoded.locale == draft.locale && decoded.appearance == draft.appearance)
        precondition(decoded.grants == draft.grants)
        precondition(decoded.settings == draft.settings)
        precondition(decoded.clock.isEnabled == false)
        precondition(decoded.fixtures.media == .explicit(directory.appendingPathComponent("media.json")))
    }

    private static func fixtureTransfer(_ manifest: PluginManifest) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-fixture-transfer-" + UUID().uuidString)
        let sourceDirectory = directory.appendingPathComponent("source")
        let scenarioDirectory = directory.appendingPathComponent("scenario")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = sourceDirectory.appendingPathComponent("media.json")
        try Data("{}".utf8).write(to: media)
        let weather = sourceDirectory.appendingPathComponent("weather.json")
        try Data("{}".utf8).write(to: weather)

        var draft = PreviewScenarioDraft.derive(manifest: manifest)
        draft.fixtures.media = .explicit(media)
        draft.fixtures.weather = .explicit(weather)
        let paths = try draft.materializeFixtures(in: scenarioDirectory)
        precondition(paths[.media] == "fixtures/media-media.json")
        precondition(paths[.weather] == "fixtures/weather-weather.json")
        let data = try draft.encode(fixtureRelativePaths: paths)
        let scenarioFile = scenarioDirectory.appendingPathComponent("scenario.json")
        try data.write(to: scenarioFile)
        // 导出后按 App 相同路径回读：schema 与 fixture 安全检查都必须通过。
        let scenarioData = try PreviewFixtureFile.read(relativePath: scenarioFile.lastPathComponent,
                                                       scenarioDirectory: scenarioDirectory,
                                                       maximumBytes: PluginStorage.maxTotalBytes)
        let scenario = try PreviewScenario.decode(scenarioData)
        precondition(scenario.fixtures?.media == paths[.media])
        precondition(FileManager.default.fileExists(atPath: scenarioDirectory.appendingPathComponent(paths[.media] ?? "").path))

        try FileManager.default.createSymbolicLink(at: sourceDirectory.appendingPathComponent("link.json"),
                                                   withDestinationURL: media)
        var linked = PreviewScenarioDraft.derive(manifest: manifest)
        linked.fixtures.fs = .explicit(sourceDirectory.appendingPathComponent("link.json"))
        do {
            _ = try linked.materializeFixtures(in: scenarioDirectory)
            fatalError("unexpectedly copied a symbolic link")
        } catch FixtureTransferError.invalidFixture {}
    }

    private static func exporter(_ manifest: PluginManifest) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-export-test-" + UUID().uuidString)
        let sourceDirectory = directory.appendingPathComponent("source")
        let exportDirectory = directory.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let media = sourceDirectory.appendingPathComponent("media.json")
        try Data("{}".utf8).write(to: media)
        var draft = PreviewScenarioDraft.derive(manifest: manifest)
        draft.fixtures.media = .explicit(media)
        draft.fixtures.weather = .none
        draft.settings["layout"] = .string("wide")
        let destination = exportDirectory.appendingPathComponent("scenario.json")

        try PreviewScenarioExporter.write(draft, to: destination)
        let first = try PreviewScenario.decode(Data(contentsOf: destination))
        let firstFolder = try first.fixtures?.media.map { try required($0) } ?? ""
        precondition(firstFolder.hasPrefix("scenario-fixtures/"))
        precondition(FileManager.default.fileExists(
            atPath: exportDirectory.appendingPathComponent(firstFolder).path))
        precondition(first.settings?["layout"] != nil)

        // 再次导出不覆盖已有 fixture 目录，而是使用带序号的新目录。
        try PreviewScenarioExporter.write(draft, to: destination)
        let second = try PreviewScenario.decode(Data(contentsOf: destination))
        let secondFolder = try second.fixtures?.media.map { try required($0) } ?? ""
        precondition(secondFolder.hasPrefix("scenario-fixtures-2/"))
        precondition(FileManager.default.fileExists(
            atPath: exportDirectory.appendingPathComponent(secondFolder).path))
        precondition(FileManager.default.fileExists(
            atPath: exportDirectory.appendingPathComponent(firstFolder).path))
    }

    /// 导出时内置样例必须复制到导出目录，并以相对路径回读通过；导出文件不再依赖 App 资源。
    private static func builtinExporter(_ manifest: PluginManifest) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Tools/PluginPreview/Resources", isDirectory: true)
        let media = resources.appendingPathComponent("PluginPreviewBuiltinMedia.json")
        let weather = resources.appendingPathComponent("PluginPreviewBuiltinWeather.json")
        precondition(FileManager.default.fileExists(atPath: media.path))
        precondition(FileManager.default.fileExists(atPath: weather.path))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-builtin-export-" + UUID().uuidString)
        let exportDirectory = directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var draft = PreviewScenarioDraft.derive(manifest: manifest)
        draft.fixtures.media = .builtin
        draft.fixtures.weather = .builtin
        let destination = exportDirectory.appendingPathComponent("scenario.json")
        try PreviewScenarioExporter.write(draft, to: destination) { kind in
            switch kind {
            case .media: return media
            case .weather: return weather
            case .fs, .activity: return nil
            }
        }

        let scenario = try PreviewScenario.decode(Data(contentsOf: destination))
        let mediaRelative = try required(scenario.fixtures?.media ?? "")
        let weatherRelative = try required(scenario.fixtures?.weather ?? "")
        precondition(mediaRelative.hasPrefix("scenario-fixtures/"))
        precondition(weatherRelative.hasPrefix("scenario-fixtures/"))
        let exportedMedia = exportDirectory.appendingPathComponent(mediaRelative)
        let exportedWeather = exportDirectory.appendingPathComponent(weatherRelative)
        let exportedMediaData = try Data(contentsOf: exportedMedia)
        let exportedWeatherData = try Data(contentsOf: exportedWeather)
        let sourceMediaData = try Data(contentsOf: media)
        let sourceWeatherData = try Data(contentsOf: weather)
        precondition(exportedMediaData == sourceMediaData)
        precondition(exportedWeatherData == sourceWeatherData)

        let mediaObject = try JSONSerialization.jsonObject(with: exportedMediaData) as? [String: Any] ?? [:]
        precondition((mediaObject["nowPlaying"] as? [String: Any])?["title"] as? String == "Synthetic Evening")
        precondition(Set(mediaObject.keys).isSubset(of: ["nowPlaying", "library", "artworkBase64"]))
        let weatherObject = try JSONSerialization.jsonObject(with: exportedWeatherData) as? [String: Any] ?? [:]
        precondition(Set(weatherObject.keys) == ["condition", "temperature", "wind", "source"])

        let roundTripped = try PreviewScenarioDraft.decode(Data(contentsOf: destination),
                                                           scenarioDirectory: exportDirectory)
        precondition(roundTripped.fixtures.media == .explicit(exportedMedia))
        precondition(roundTripped.fixtures.weather == .explicit(exportedWeather))
    }

    /// 契约 §3.2/§3.4：inspect 的 source 与缺失 fixture 的固定修复提示。
    private static func missingFixtureReporting(_ manifest: PluginManifest) throws {
        let data = try PluginPreviewInspectReport.data(manifest: manifest)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let fixtures = object["fixtures"] as? [[String: Any]] ?? []
        precondition(fixtures.map { $0["source"] as? String } == ["builtin", "builtin", "none", "none"])

        let fs = try fsManifest()
        let fsData = try PluginPreviewInspectReport.data(manifest: fs)
        let fsObject = try JSONSerialization.jsonObject(with: fsData) as? [String: Any] ?? [:]
        let fsFixtures = fsObject["fixtures"] as? [[String: Any]] ?? []
        precondition(fsFixtures[2]["needed"] as? Bool == true)
        precondition(fsFixtures[2]["source"] as? String == "none")
        precondition(fsFixtures[2]["reason"] as? String
            == "manifest declares fs.read; requires an explicit fixture file")

        let message = PreviewFixtureHint.message(kind: .fs, localize: { _ in PreviewFixtureHint.messageKey })
        precondition(message == "This plugin needs a fs fixture. Pick a file in Custom mode or use --fixture fs=<file>.")

        let activity = try makeManifest(permissions: ["activity.read"])
        let activityData = try PluginPreviewInspectReport.data(manifest: activity)
        let activityObject = try JSONSerialization.jsonObject(with: activityData) as? [String: Any] ?? [:]
        let activityFixtures = activityObject["fixtures"] as? [[String: Any]] ?? []
        precondition(activityFixtures[3]["needed"] as? Bool == true)
        precondition(activityFixtures[3]["source"] as? String == "none")
        precondition(activityFixtures[3]["reason"] as? String
            == "manifest declares activity.read; requires an explicit synthetic fixture")
    }

    private static func required(_ value: String) throws -> String {
        guard !value.isEmpty else { throw FixtureTransferError.invalidFixture }
        return value
    }

    private static func commandLine() throws {
        func expectInvalid(_ args: [String]) {
            do {
                _ = try PluginPreviewCommandLine.parse(args)
                fatalError("unexpectedly accepted arguments: \(args)")
            } catch PluginPreviewCommandLineError.invalidArguments {}
            catch { fatalError("unexpected error: \(error)") }
        }

        let launcher = try PluginPreviewCommandLine.parse([])
        precondition(launcher == .launcher)
        let inspect = try PluginPreviewCommandLine.parse(["inspect", "/tmp/plugin"])
        guard case .inspect(let inspected) = inspect else { fatalError("expected inspect") }
        precondition(inspected.path == "/tmp/plugin")
        expectInvalid(["inspect", "/tmp/plugin", "--json"])
        expectInvalid(["inspect", "/tmp/plugin", "--locale", "en"])

        let preview = try PluginPreviewCommandLine.parse([
            "dev", "/tmp/plugin", "--locale", "zh-Hans", "--appearance", "dark",
            "--glass", "--no-reduce-motion", "--width", "320", "--grants", "none",
            "--set", "layout=wide", "--fixture", "fs=/tmp/fixture.json",
            "--target-bundle-id", "com.example.other", "--target-app-name", "Other",
        ])
        guard case .preview(let arguments) = preview else { fatalError("expected preview") }
        precondition(arguments.command == "dev" && arguments.scenario == nil && arguments.output == nil)
        precondition(arguments.overrides.locale == .zhHans && arguments.overrides.appearance == .dark)
        precondition(arguments.overrides.glass == true && arguments.overrides.reduceMotion == false)
        precondition(arguments.overrides.width == 320)
        precondition(arguments.overrides.grants == [])
        precondition(arguments.overrides.settings["layout"] == "wide")
        precondition(arguments.overrides.fixtures[.fs]?.path == "/tmp/fixture.json")
        precondition(arguments.overrides.targetBundleID == "com.example.other")

        let run = try PluginPreviewCommandLine.parse(["run", "/tmp/plugin", "--out", "/tmp/out", "--json"])
        guard case .preview(let runArguments) = run else { fatalError("expected run") }
        precondition(runArguments.output?.path == "/tmp/out" && runArguments.json)

        // 显式场景与覆盖项互斥；`--scenario` 单独使用仍合法。
        expectInvalid(["dev", "/tmp/plugin", "--scenario", "/tmp/scenario.json", "--locale", "en"])
        expectInvalid(["dev", "/tmp/plugin", "--scenario", "/tmp/scenario.json", "--glass"])
        _ = try PluginPreviewCommandLine.parse(["dev", "/tmp/plugin", "--scenario", "/tmp/scenario.json"])
        expectInvalid(["run", "/tmp/plugin"])
        expectInvalid(["dev", "/tmp/plugin", "--out", "/tmp/out"])
        expectInvalid(["dev", "/tmp/plugin", "--width", "1000"])
        expectInvalid(["dev", "/tmp/plugin", "--locale", "fr"])
        expectInvalid(["dev", "/tmp/plugin", "--glass", "--no-glass"])
        expectInvalid(["dev", "/tmp/plugin", "--grants", "a,,b"])
        expectInvalid(["dev", "/tmp/plugin", "--grants", "a,a"])
        expectInvalid(["dev", "/tmp/plugin", "--set", "bad"])
        expectInvalid(["dev", "/tmp/plugin", "--set", "layout=wide", "--set", "layout=compact"])
        expectInvalid(["dev", "/tmp/plugin", "--fixture", "video=/tmp/a.json"])
        expectInvalid(["dev", "/tmp/plugin", "--fixture", "media"])
        expectInvalid(["dev", "/tmp/plugin", "--unknown"])
    }

    private static func inspectReport(_ manifest: PluginManifest) throws {
        let data = try PluginPreviewInspectReport.data(manifest: manifest)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        precondition(object["schemaVersion"] as? Int == 1)
        let plugin = object["plugin"] as? [String: Any] ?? [:]
        precondition(plugin["id"] as? String == manifest.id)
        precondition(plugin["permissions"] as? [String] == ["media.nowPlaying", "weather.current"])
        precondition(plugin["matches"] as? [String] == manifest.matches)

        let scenario = object["defaultScenario"] as? [String: Any] ?? [:]
        precondition(scenario["id"] as? String == "default")
        let environment = scenario["environment"] as? [String: Any] ?? [:]
        precondition(environment["contentWidthPoints"] as? Double == 360)
        let target = scenario["target"] as? [String: Any] ?? [:]
        precondition(target["bundleID"] as? String == "com.example.app")

        let settings = object["settings"] as? [[String: Any]] ?? []
        precondition(settings.count == 3)
        precondition(settings[0]["kind"] as? String == "toggle" && settings[0]["default"] as? Bool == true)
        precondition(settings[1]["kind"] as? String == "select")
        precondition(settings[1]["options"] as? [String] == ["compact", "wide"])
        precondition(settings[2]["kind"] as? String == "number")
        precondition(settings[2]["min"] as? Double == 300 && settings[2]["max"] as? Double == 720)
        precondition(settings[2]["step"] as? Double == 20)

        let fixtures = object["fixtures"] as? [[String: Any]] ?? []
        precondition(fixtures.map { $0["kind"] as? String } == ["media", "weather", "fs", "activity"])
        precondition(fixtures.map { $0["needed"] as? Bool } == [true, true, false, false])
        precondition(fixtures.map { $0["source"] as? String } == ["builtin", "builtin", "none", "none"])
        precondition(fixtures[2]["reason"] as? String == "manifest does not declare fs.read")
        precondition(fixtures[3]["reason"] as? String == "manifest does not declare activity.read")
    }
}
