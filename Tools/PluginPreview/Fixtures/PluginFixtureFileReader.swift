import Foundation

/// Deterministic, in-memory implementation of the host's read-only fs boundary.
/// It never resolves paths or touches the real filesystem, so previews cannot
/// accidentally read a user's home directory or inherit host grants.
final class PluginFixtureFileReader: PluginFileReading, @unchecked Sendable {
    static let maxFixtureRoots = 32
    static let maxFixtureEntriesPerRoot = PluginFileReader.maxScanVisited
    static let maxFixturePathBytes = 4096

    struct Entry: Decodable {
        let path: String
        let isDirectory: Bool
        let text: String
        let modified: Double
        let locked: Bool

        init(path: String, isDirectory: Bool = false, text: String = "", modified: Double = 0, locked: Bool = false) {
            self.path = path
            self.isDirectory = isDirectory
            self.text = text
            self.modified = modified
            self.locked = locked
        }

        private enum CodingKeys: String, CodingKey { case path, isDirectory, text, modified, locked }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            isDirectory = try values.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
            text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
            modified = try values.decodeIfPresent(Double.self, forKey: .modified) ?? 0
            locked = try values.decodeIfPresent(Bool.self, forKey: .locked) ?? false
            guard modified.isFinite else { throw PluginFSError.denied }
        }
    }

    struct Root: Decodable {
        let entries: [Entry]
    }

    private struct Fixture: Decodable {
        let roots: [String: Root]
    }

    private struct Node {
        let isDirectory: Bool
        let text: String
        let modified: Double
        let locked: Bool
    }

    private let roots: [String: [String: Node]]
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var calls = 0

    var rootIDs: Set<String> { Set(roots.keys) }

    init(roots: [String: Root], now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        guard roots.count <= Self.maxFixtureRoots else { throw PluginFSError.tooLarge }
        self.now = now
        var built: [String: [String: Node]] = [:]
        for (id, root) in roots {
            guard !id.isEmpty, id.utf8.count <= 256,
                  root.entries.count <= Self.maxFixtureEntriesPerRoot else { throw PluginFSError.tooLarge }
            var nodes: [String: Node] = ["": Node(isDirectory: true, text: "", modified: 0, locked: false)]
            var declared = Set<String>()
            let ordered = try root.entries.map { entry -> (String, Entry) in
                let path = try Self.pluginPath(entry.path)
                guard !path.isEmpty, path.utf8.count <= Self.maxFixturePathBytes,
                      entry.text.utf8.count <= PluginFileReader.maxReadBytes,
                      entry.modified.isFinite,
                      declared.insert(path).inserted else { throw PluginFSError.denied }
                return (path, entry)
            }.sorted {
                let leftDepth = $0.0.split(separator: "/").count
                let rightDepth = $1.0.split(separator: "/").count
                return leftDepth == rightDepth ? $0.0 < $1.0 : leftDepth < rightDepth
            }

            for (path, entry) in ordered {
                let parts = path.split(separator: "/").map(String.init)
                for depth in 1..<parts.count {
                    let parent = parts[..<depth].joined(separator: "/")
                    if let node = nodes[parent], !node.isDirectory { throw PluginFSError.denied }
                    if nodes[parent] == nil {
                        nodes[parent] = Node(isDirectory: true, text: "", modified: 0, locked: false)
                    }
                }
                if let existing = nodes[path], existing.isDirectory != entry.isDirectory {
                    throw PluginFSError.denied
                }
                nodes[path] = Node(isDirectory: entry.isDirectory, text: entry.text,
                                   modified: entry.modified, locked: entry.locked)
            }
            built[id] = nodes
        }
        self.roots = built
    }

    /// Preview fixture shape: `{"roots":{"<id>":{"entries":[...]}}}`.
    static func decode(_ data: Data, now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) throws -> PluginFixtureFileReader {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["roots"], let roots = object["roots"] as? [String: Any] else {
            throw PluginFSError.denied
        }
        for value in roots.values {
            guard let root = value as? [String: Any], Set(root.keys) == ["entries"],
                  let entries = root["entries"] as? [[String: Any]], entries.allSatisfy({ entry in
                      Set(entry.keys).isSubset(of: ["path", "isDirectory", "text", "modified", "locked"])
                          && entry.values.allSatisfy { !($0 is NSNull) }
                  }) else { throw PluginFSError.denied }
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        return try PluginFixtureFileReader(roots: fixture.roots, now: now)
    }

    func resetCalls() {
        lock.lock()
        calls = 0
        lock.unlock()
    }

    func list(root: String, path: String) throws -> [PluginFSEntry] {
        let (target, node, _) = try resolve(root: root, path: path)
        guard node.isDirectory else { throw PluginFSError.denied }
        let prefix = target.isEmpty ? "" : target + "/"
        let names = roots[root]!.keys.compactMap { candidate -> String? in
            guard candidate != target, candidate.hasPrefix(prefix) else { return nil }
            let rest = candidate.dropFirst(prefix.count)
            return rest.isEmpty || rest.contains("/") ? nil : String(rest)
        }.sorted()
        guard names.count <= PluginFileReader.maxListEntries else { throw PluginFSError.tooLarge }
        return names.compactMap { name in
            let child = prefix + name
            return roots[root].flatMap { nodes in nodes[child].map { entry(name: name, node: $0) } }
        }
    }

    func stat(root: String, path: String) throws -> PluginFSEntry {
        let (target, node, id) = try resolve(root: root, path: path)
        let name = target.split(separator: "/").last.map(String.init) ?? id
        return entry(name: name, node: node)
    }

    func readText(root: String, path: String, maxBytes: Int? = nil) throws -> String {
        let (_, node, _) = try resolve(root: root, path: path)
        guard !node.isDirectory else { throw PluginFSError.denied }
        let limit = min(maxBytes.map { max(0, $0) } ?? PluginFileReader.maxReadBytes, PluginFileReader.maxReadBytes)
        guard node.text.utf8.count <= limit else { throw PluginFSError.tooLarge }
        return node.text
    }

    func scan(root: String, path: String, depth: Int, suffix: String?, modifiedWithin: TimeInterval?) throws -> [PluginFSScanEntry] {
        let (target, node, _) = try resolve(root: root, path: path)
        guard node.isDirectory else { throw PluginFSError.denied }
        let prefix = target.isEmpty ? "" : target + "/"
        let maxDepth = min(max(depth, 1), PluginFileReader.maxScanDepth)
        let cutoff = modifiedWithin.map { now() - $0 }
        var found: [PluginFSScanEntry] = []
        var visited = 0

        for candidate in roots[root]!.keys.sorted() where candidate != target && candidate.hasPrefix(prefix) {
            visited += 1
            if visited > PluginFileReader.maxScanVisited { break }
            guard let child = roots[root]?[candidate], !child.isDirectory else { continue }
            let relative = String(candidate.dropFirst(prefix.count))
            guard relative.split(separator: "/").count <= maxDepth,
                  suffix.map({ relative.hasSuffix($0) }) ?? true,
                  cutoff.map({ child.modified >= $0 }) ?? true else { continue }
            found.append(PluginFSScanEntry(path: relative, size: child.text.utf8.count, modified: child.modified))
        }
        return Array(found.sorted {
            if $0.modified == $1.modified { return $0.path < $1.path }
            return $0.modified > $1.modified
        }.prefix(PluginFileReader.maxScanResults))
    }

    func isLocked(root: String, path: String) throws -> Bool {
        let (_, node, _) = try resolve(root: root, path: path)
        guard !node.isDirectory else { throw PluginFSError.denied }
        return node.locked
    }

    private func resolve(root: String, path: String) throws -> (target: String, node: Node, root: String) {
        try spendCall()
        guard let nodes = roots[root] else { throw PluginFSError.denied }
        let target = try Self.pluginPath(path)
        guard let node = nodes[target] else { throw PluginFSError.notFound }
        return (target, node, root)
    }

    private func spendCall() throws {
        lock.lock()
        defer { lock.unlock() }
        guard calls < PluginFileReader.maxCallsPerRender else { throw PluginFSError.tooManyCalls }
        calls += 1
    }

    private func entry(name: String, node: Node) -> PluginFSEntry {
        PluginFSEntry(name: name, isDirectory: node.isDirectory, size: node.text.utf8.count, modified: node.modified)
    }

    private static func pluginPath(_ path: String) throws -> String {
        let normalized = path == "." ? "" : path
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !segments.contains(where: { $0 == ".." || ($0.isEmpty && normalized != "") }) else {
            throw PluginFSError.denied
        }
        return normalized
    }
}
