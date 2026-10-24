//
//  PluginRegistry.swift
//  Switchly
//
//  Discovers installed plugins under Application Support/Switchly/Plugins.
//  Local files only; nothing is fetched.
//

import Foundation

/// Where a package came from. Every origin is loaded from a local directory
/// by the same loader; a future remote origin (e.g. a GitHub repo pinned to a
/// commit) only adds a fetch-and-verify step that materializes that directory
/// first — see docs/dock-preview-plugins-design.md D05.
enum PluginOrigin: Equatable {
    /// Shipped inside Switchly.app/Contents/Resources/Plugins.
    case builtin
    /// Installed by the user under Application Support.
    case user
}

struct PluginPackage: Equatable {
    let manifest: PluginManifest
    let directory: URL
    let source: String
    let origin: PluginOrigin
}

struct PluginSearchPath: Equatable {
    let directory: URL
    let origin: PluginOrigin
}

struct PluginLoadFailure: Equatable {
    let directory: URL
    let reason: String
}

protocol PluginRegistryProtocol {
    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure])
}

final class PluginRegistry: PluginRegistryProtocol {
    /// Bundles larger than this are rejected before evaluation.
    static let maxEntrySize = 2 * 1024 * 1024

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Switchly/Plugins", isDirectory: true)
    }

    static var builtinDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true)
    }

    static var defaultSearchPaths: [PluginSearchPath] {
        (builtinDirectory.map { [PluginSearchPath(directory: $0, origin: .builtin)] } ?? [])
            + [PluginSearchPath(directory: defaultDirectory, origin: .user)]
    }

    private let searchPaths: [PluginSearchPath]
    private let fileManager: FileManager

    /// Earlier paths win on duplicate ids, so a user copy cannot shadow a
    /// built-in plugin.
    init(searchPaths: [PluginSearchPath] = PluginRegistry.defaultSearchPaths, fileManager: FileManager = .default) {
        self.searchPaths = searchPaths
        self.fileManager = fileManager
    }

    convenience init(directory: URL, origin: PluginOrigin = .user) {
        self.init(searchPaths: [PluginSearchPath(directory: directory, origin: origin)])
    }

    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure]) {
        var plugins: [PluginPackage] = []
        var failures: [PluginLoadFailure] = []
        var seenIDs = Set<String>()
        for path in searchPaths {
            let entries = (try? fileManager.contentsOfDirectory(
                at: path.directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                do {
                    let package = try load(from: entry, origin: path.origin)
                    guard seenIDs.insert(package.manifest.id).inserted else {
                        throw LoadError("duplicate id \(package.manifest.id)")
                    }
                    plugins.append(package)
                } catch {
                    let reason = (error as? LoadError)?.message ?? String(describing: error)
                    AppLogger.warning("Plugin load failed. dir=\(entry.lastPathComponent) reason=\(reason)")
                    failures.append(PluginLoadFailure(directory: entry, reason: reason))
                }
            }
        }
        AppLogger.info("Plugins reloaded. loaded=\(plugins.count) failed=\(failures.count)")
        return (plugins, failures)
    }

    private struct LoadError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func load(from dir: URL, origin: PluginOrigin) throws -> PluginPackage {
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        } catch {
            throw LoadError("missing manifest.json")
        }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        try manifest.validate()

        let entryURL = dir.appendingPathComponent(manifest.entry).standardizedFileURL
        guard entryURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else { throw LoadError("entry escapes plugin") }
        let size = (try? entryURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxEntrySize else { throw LoadError("entry too large bytes=\(size)") }
        guard let source = try? String(contentsOf: entryURL, encoding: .utf8) else { throw LoadError("unreadable entry") }
        return PluginPackage(manifest: manifest, directory: dir, source: source, origin: origin)
    }
}
