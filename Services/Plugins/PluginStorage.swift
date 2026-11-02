import Foundation

/// 插件私有 JSON 状态；不接受路径，不保存宿主设置或其他插件的数据。
final class PluginStorage {
    static let maxValueBytes = 64 * 1024
    static let maxTotalBytes = 1024 * 1024
    private static let ioLock = NSLock()
    private let url: URL

    init(pluginID: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchly/PluginData", isDirectory: true)
        // 生产调用来自已验证 manifest；摘要也防止测试或未来调用引入路径。
        let safeID = Data(pluginID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        url = base.appendingPathComponent(safeID + ".json")
    }

    func get(_ key: String) throws -> Any? {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        return try read()[key]
    }

    func set(_ key: String, value: Any) throws {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        guard !key.isEmpty, key.utf8.count <= 256 else { throw Failure.invalidKey }
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard encoded.count <= Self.maxValueBytes else { throw Failure.quotaExceeded }
        var values = try read()
        values[key] = value
        try write(values)
    }

    func remove(_ key: String) throws {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        var values = try read()
        values.removeValue(forKey: key)
        try write(values)
    }

    func clear() throws {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    enum Failure: Error { case invalidKey, quotaExceeded, invalidData }

    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard properties.isSymbolicLink != true, (properties.fileSize ?? 0) <= Self.maxTotalBytes else {
            throw Failure.invalidData
        }
        guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.invalidData
        }
        return values
    }

    private func write(_ values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard data.count <= Self.maxTotalBytes else { throw Failure.quotaExceeded }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
