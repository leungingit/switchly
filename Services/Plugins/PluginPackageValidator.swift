import Foundation

/// 安装和发现共用的离线校验入口；先限制整个包，再读取 manifest 和入口。
enum PluginPackageValidator {
    static let maxFiles = 1024
    static let maxPackageBytes = 32 * 1024 * 1024
    static let maxManifestBytes = 256 * 1024
    static let maxEntryBytes = 2 * 1024 * 1024

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func load(directory: URL, origin: PluginOrigin, fileManager: FileManager = .default) throws -> PluginPackage {
        let root = directory.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw Failure(reason: "package must be a directory, not a symbolic link")
        }
        var scanError: Error?
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                 options: [], errorHandler: { _, error in scanError = error; return false }) else {
            throw Failure(reason: "unreadable package")
        }
        var bytes = 0
        var files = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw Failure(reason: "symbolic links are not allowed") }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw Failure(reason: "unsupported package entry")
            }
            files += 1
            guard files <= maxFiles else { throw Failure(reason: "too many package entries") }
            if values.isRegularFile == true {
                bytes += values.fileSize ?? 0
                guard bytes <= maxPackageBytes else { throw Failure(reason: "package exceeds byte budget") }
            }
        }
        if let scanError { throw scanError }
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= maxManifestBytes else {
            throw Failure(reason: "manifest exceeds byte budget")
        }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        let entry = root.appendingPathComponent(manifest.entry).standardizedFileURL
        guard entry.path.hasPrefix(root.path + "/"),
              try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure(reason: "invalid entry")
        }
        guard try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= maxEntryBytes else {
            throw Failure(reason: "entry exceeds byte budget")
        }
        return PluginPackage(manifest: manifest, directory: root,
                             source: try String(contentsOf: entry, encoding: .utf8), origin: origin)
    }
}
