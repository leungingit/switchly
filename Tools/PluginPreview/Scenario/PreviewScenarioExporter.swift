import Foundation

/// 把草稿导出为场景文件（契约 §3.3）：
/// fixtures 先经 `materializeFixtures` 落到临时目录，再复制到导出目录下的独立子目录，
/// 场景内只写相对路径；写出后立刻按 `run` 相同路径回读校验。
enum PreviewScenarioExporter {
    /// 内置样例默认从 App bundle 读取；测试可注入临时目录中的样例文件。
    static func write(_ draft: PreviewScenarioDraft, to destination: URL,
                      builtinFixtureURL: (PreviewScenarioDraft.FixtureKind) -> URL? = {
                          BuiltinFixtureSample.url(for: $0)
                      }) throws {
        let directory = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-preview-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let relative = try draft.materializeFixtures(in: staging, builtinFixtureURL: builtinFixtureURL)
        var adjusted: [PreviewScenarioDraft.FixtureKind: String] = [:]
        var copiedFolder: URL?
        if !relative.isEmpty {
            let folderName = try uniqueFixtureFolderName(base: base, in: directory)
            let folder = directory.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            copiedFolder = folder
            let staged = staging.appendingPathComponent("fixtures", isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil) {
                try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
            for (kind, path) in relative {
                adjusted[kind] = folderName + "/" + (path as NSString).lastPathComponent
            }
        }

        var wroteDestination = false
        do {
            let data = try draft.encode(fixtureRelativePaths: adjusted)
            try data.write(to: destination, options: [.atomic])
            wroteDestination = true
            let readBack = try PreviewFixtureFile.read(relativePath: destination.lastPathComponent,
                                                       scenarioDirectory: directory,
                                                       maximumBytes: PluginStorage.maxTotalBytes)
            let scenario = try PreviewScenario.decode(readBack)
            let paths = [scenario.fixtures?.media, scenario.fixtures?.weather, scenario.fixtures?.fs, scenario.fixtures?.activity].compactMap { $0 }
            for path in paths {
                _ = try PreviewFixtureFile.read(relativePath: path, scenarioDirectory: directory,
                                                maximumBytes: PluginPackageValidator.maxPackageBytes)
            }
        } catch {
            if wroteDestination { try? FileManager.default.removeItem(at: destination) }
            if let copiedFolder { try? FileManager.default.removeItem(at: copiedFolder) }
            throw error
        }
    }

    /// 不覆盖既有目录：`scenario-fixtures`、`scenario-fixtures-2`……
    private static func uniqueFixtureFolderName(base: String, in directory: URL) throws -> String {
        let stem = base.isEmpty ? "scenario" : base
        for index in 1...99 {
            let name = index == 1 ? "\(stem)-fixtures" : "\(stem)-fixtures-\(index)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return name
            }
        }
        throw FixtureTransferError.invalidFixture
    }
}
