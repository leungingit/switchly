//
//  PluginFileReader.swift
//  Switchly
//
//  Read-only access to the folders a plugin declared in `fsRoots`, behind the
//  `fs.read` permission (design doc §8.6). Plugins name a root id and a
//  relative path; they never see or choose absolute paths. Every path is
//  resolved through symlinks and must still sit inside the root.
//

import Foundation

enum PluginFSError: Error, Equatable {
    /// Unknown root, unsafe path, sensitive location or an entry outside the root.
    case denied
    case notFound
    case tooLarge
    case notText
    case tooManyCalls
}

struct PluginFSEntry: Equatable {
    let name: String
    let isDirectory: Bool
    let size: Int
    /// Seconds since 1970.
    let modified: Double

    var jsObject: [String: Any] { ["name": name, "isDir": isDirectory, "size": size, "mtime": modified] }
}

/// One file found by `scan`, with its path relative to the root.
struct PluginFSScanEntry: Equatable {
    let path: String
    let size: Int
    let modified: Double

    var jsObject: [String: Any] { ["path": path, "size": size, "mtime": modified] }
}

/// The narrow boundary `PluginRuntime` needs for `ctx.fs`. The host uses the
/// real reader; preview and tests can provide a deterministic in-memory one.
protocol PluginFileReading: AnyObject {
    func resetCalls()
    func list(root: String, path: String) throws -> [PluginFSEntry]
    func stat(root: String, path: String) throws -> PluginFSEntry
    func readText(root: String, path: String, maxBytes: Int?) throws -> String
    func scan(root: String, path: String, depth: Int, suffix: String?, modifiedWithin: TimeInterval?) throws -> [PluginFSScanEntry]
    func isLocked(root: String, path: String) throws -> Bool
}

final class PluginFileReader: PluginFileReading, @unchecked Sendable {
    static let maxReadBytes = 256 * 1024
    static let maxListEntries = 500
    static let maxCallsPerRender = 50
    static let maxScanResults = 200
    static let maxScanVisited = 5000
    static let maxScanDepth = 3

    private let roots: [String: PluginFSRoot]
    private let home: URL
    private let lock = NSLock()
    private var calls = 0

    init(roots: [PluginFSRoot], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.roots = Dictionary(roots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.home = home
    }

    /// Starts a new render / action: the per-call quota begins again.
    func resetCalls() {
        lock.lock()
        calls = 0
        lock.unlock()
    }

    func list(root: String, path: String) throws -> [PluginFSEntry] {
        let (base, url) = try resolve(root: root, path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw PluginFSError.notFound }
        guard isDirectory.boolValue else { throw PluginFSError.denied }
        let names = try contents(of: url)
        guard names.count <= Self.maxListEntries else { throw PluginFSError.tooLarge }
        // Entries whose real location leaves the root are hidden rather than reported.
        return names.compactMap { name in try? entry(at: url.appendingPathComponent(name), under: base) }
            .sorted { $0.name < $1.name }
    }

    func stat(root: String, path: String) throws -> PluginFSEntry {
        let (base, url) = try resolve(root: root, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PluginFSError.notFound }
        return try entry(at: url, under: base)
    }

    func readText(root: String, path: String, maxBytes: Int? = nil) throws -> String {
        let (_, url) = try resolve(root: root, path: path)
        let limit = min(maxBytes.map { max(0, $0) } ?? Self.maxReadBytes, Self.maxReadBytes)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard FileManager.default.fileExists(atPath: url.path) else { throw PluginFSError.notFound }
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw PluginFSError.denied }
        guard size <= limit else { throw PluginFSError.tooLarge }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw PluginFSError.notText }
        return text
    }

    /// Files below a folder, newest first: at most `maxScanDepth` levels deep, optionally only names ending in
    /// `suffix` and modified within `modifiedWithin` seconds. One call replaces a walk of many `list`s.
    func scan(root: String, path: String, depth: Int, suffix: String?, modifiedWithin: TimeInterval?) throws -> [PluginFSScanEntry] {
        let (base, url) = try resolve(root: root, path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw PluginFSError.notFound }
        guard isDirectory.boolValue else { throw PluginFSError.denied }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { throw PluginFSError.notFound }
        let maxDepth = min(max(depth, 1), Self.maxScanDepth)
        let cutoff = modifiedWithin.map { Date().timeIntervalSince1970 - $0 }
        var found: [PluginFSScanEntry] = []
        var visited = 0
        for case let item as URL in walker {
            visited += 1
            if visited > Self.maxScanVisited { break }
            let values = try? item.resourceValues(forKeys: Set(keys))
            // Links are never followed during a scan.
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isDirectory == true {
                if walker.level >= maxDepth { walker.skipDescendants() }
                continue
            }
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            // `resolvingSymlinksInPath` on both sides, so "/private/var" and "/var" spellings cannot disagree.
            let real = item.resolvingSymlinksInPath()
            guard suffix.map({ item.lastPathComponent.hasSuffix($0) }) ?? true, cutoff.map({ modified >= $0 }) ?? true,
                  Self.contains(base, real), real.path.count > url.path.count else { continue }
            found.append(PluginFSScanEntry(path: String(real.path.dropFirst(url.path.count + 1)),
                                           size: values?.fileSize ?? 0, modified: modified))
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(Self.maxScanResults))
    }

    /// Whether another process holds an `flock` on this file (a session lock, say). Takes a shared lock
    /// without waiting and drops it again at once; nothing is read or written.
    func isLocked(root: String, path: String) throws -> Bool {
        let (_, url) = try resolve(root: root, path: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard FileManager.default.fileExists(atPath: url.path) else { throw PluginFSError.notFound }
        guard values?.isRegularFile == true else { throw PluginFSError.denied }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { throw PluginFSError.denied }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK { return true }
        throw PluginFSError.denied
    }

    // MARK: - Resolution

    /// The real root and the real target. Both are symlink-resolved, so a link that
    /// points outside the root is caught by the prefix check.
    private func resolve(root id: String, path: String) throws -> (base: URL, url: URL) {
        try spendCall()
        guard let declared = roots[id], declared.isAcceptable(home: home) else { throw PluginFSError.denied }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\0"),
              !segments.contains(where: { $0 == ".." || ($0.isEmpty && path != "") }) else { throw PluginFSError.denied }

        let base = declared.url(home: home).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw PluginFSError.notFound }
        // A link that makes an allowed-looking root land on a sensitive folder is refused too.
        let homeReal = home.resolvingSymlinksInPath()
        let real = PluginFSRoot(id: id, path: base.path, summary: [:])
        guard real.isAcceptable(home: homeReal), try !holdsSecrets(base) else { throw PluginFSError.denied }

        let target = path.isEmpty || path == "." ? base : base.appendingPathComponent(path).resolvingSymlinksInPath()
        guard Self.contains(base, target) else { throw PluginFSError.denied }
        return (base, target)
    }

    private func spendCall() throws {
        lock.lock()
        defer { lock.unlock() }
        guard calls < Self.maxCallsPerRender else { throw PluginFSError.tooManyCalls }
        calls += 1
    }

    private static func contains(_ base: URL, _ target: URL) -> Bool {
        target.path == base.path || target.path.hasPrefix(base.path + "/")
    }

    private func contents(of url: URL) throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// A folder with credentials at its top level is not a session folder.
    private func holdsSecrets(_ base: URL) throws -> Bool {
        try contents(of: base).contains { PluginFSRoot.secretFileNames.contains($0) }
    }

    private func entry(at url: URL, under base: URL) throws -> PluginFSEntry {
        let real = url.resolvingSymlinksInPath()
        guard Self.contains(base, real) else { throw PluginFSError.denied }
        let values = try real.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return PluginFSEntry(name: url.lastPathComponent, isDirectory: values.isDirectory ?? false,
                             size: values.fileSize ?? 0,
                             modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
}
