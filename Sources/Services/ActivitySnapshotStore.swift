import AppKit
import ImageIO
import UniformTypeIdentifiers

actor ActivitySnapshotStore {
    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let sessionID: UUID
        let bundleID: String
        let capturedAt: Date
    }
    private let directory: URL
    private let now: () -> Date
    private var generation: UUID?
    private let fm = FileManager.default
    private let maxBytes = 256 * 1024 * 1024
    private let maxImageBytes = 1024 * 1024

    init(directory: URL = ActivityStore.defaultDirectory.appendingPathComponent("Snapshots"), now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.now = now
    }
    func begin(generation: UUID) { self.generation = generation }

    func save(_ image: CGImage, session: ActivitySession, generation: UUID, retentionDays: Int) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        try prepare()
        try prune(retentionDays: retentionDays)
        let scale = min(1, 640 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw WindowCaptureFailure.captureFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { throw WindowCaptureFailure.captureFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw WindowCaptureFailure.captureFailed }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= maxImageBytes else { throw WindowCaptureFailure.tooLarge }
        let entry = Entry(id: UUID(), sessionID: session.id, bundleID: session.bundleID, capturedAt: now())
        let url = directory.appendingPathComponent(entry.id.uuidString + ".jpg")
        try Task.checkCancellation()
        try privateWrite(data as Data, to: url)
        do {
            try Task.checkCancellation()
            var entries = try load(); entries.append(entry)
            try writeIndex(entries)
        } catch { try? fm.removeItem(at: url); throw error }
        try prune(retentionDays: retentionDays)
    }
    func list(from: Date, to: Date, retentionDays: Int) throws -> [Entry] {
        try prune(retentionDays: retentionDays)
        return try load().filter { $0.capturedAt >= from && $0.capturedAt < to }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt < $1.capturedAt }
    }
    func image(id: UUID, retentionDays: Int) throws -> NSImage? {
        try prune(retentionDays: retentionDays)
        guard try load().contains(where: { $0.id == id }) else { return nil }
        let url = directory.appendingPathComponent(id.uuidString + ".jpg")
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maxImageBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }
    func clear(generation: UUID) throws {
        self.generation = generation
        guard fm.fileExists(atPath: directory.path) else { return }
        try prepare()
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try fm.removeItem(at: file) }
    }
    func prune(retentionDays: Int) throws {
        guard fm.fileExists(atPath: directory.path) else { return }
        try prepare()
        let cutoff = now().addingTimeInterval(-Double([1,7,30,90].contains(retentionDays) ? retentionDays : 7) * 86400)
        let loaded = try load()
        var retained = loaded.filter { $0.capturedAt >= cutoff && $0.capturedAt <= now() }.sorted { $0.capturedAt < $1.capturedAt }
        var total = 0
        var keep: [Entry] = []
        for entry in retained.reversed() {
            let url = directory.appendingPathComponent(entry.id.uuidString + ".jpg")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 && size <= maxImageBytes && total + size <= maxBytes && keep.count < 20000 { total += size; keep.append(entry) }
        }
        retained = keep.reversed()
        let files = Set(retained.map { $0.id.uuidString + ".jpg" }).union(["index.json"])
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !files.contains(file.lastPathComponent) {
            try fm.removeItem(at: file)
        }
        if retained != loaded { try writeIndex(retained) }
    }
    private func prepare() throws {
        if fm.fileExists(atPath: directory.path), try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ActivityStoreError.unsafeStorage }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func load() throws -> [Entry] {
        let url = directory.appendingPathComponent("index.json")
        guard fm.fileExists(atPath: url.path) else { return [] }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw ActivityStoreError.unsafeStorage }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([Entry].self, from: Data(contentsOf: url))
    }
    private func writeIndex(_ entries: [Entry]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try privateWrite(encoder.encode(entries), to: directory.appendingPathComponent("index.json"))
    }
    private func privateWrite(_ data: Data, to url: URL) throws {
        let temp = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw WindowCaptureFailure.captureFailed }
        defer { try? fm.removeItem(at: temp) }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: url) }
    }
}
