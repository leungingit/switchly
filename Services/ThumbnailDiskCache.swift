import AppKit
import CryptoKit
import Darwin
import Foundation

struct PersistedThumbnail {
    let image: NSImage
    let capturedAt: Date
    let pixelSize: CGSize
}

protocol ThumbnailDiskCaching {
    func load(for window: WindowInfo) async -> PersistedThumbnail?
    func save(_ thumbnail: PersistedThumbnail, for window: WindowInfo)
    func flush(timeout: TimeInterval)
}

extension ThumbnailDiskCaching {
    func flush(timeout: TimeInterval) {}
}

/// 身份包含系统启动会话和目标进程启动时间；不能把重开的应用当作原来的窗口。
struct ThumbnailDiskIdentity: Codable {
    let bootSession: String
    let bundlePath: String
    let processID: pid_t
    let processLaunchDate: Date
    let windowID: CGWindowID
    let title: String

    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(_ window: WindowInfo) -> ThumbnailDiskIdentity? {
        guard let bootSession = currentBootSession,
              let app = NSRunningApplication(processIdentifier: window.ownerPID),
              !app.isTerminated,
              let launchDate = app.launchDate,
              let bundleURL = app.bundleURL else { return nil }
        return ThumbnailDiskIdentity(
            bootSession: bootSession,
            bundlePath: bundleURL.standardizedFileURL.path,
            processID: window.ownerPID,
            processLaunchDate: launchDate,
            windowID: window.id,
            title: window.windowTitle
        )
    }

    private static let currentBootSession: String? = {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()
}

/// 所有目录扫描、图片编解码及原子写入都在专用串行队列执行。
/// 文件只包含身份摘要、截图时间、尺寸和压缩小图，不记录明文窗口标题。
// 可变文件状态只在 queue 访问；对外读写通过队列和 continuation 串行交付。
final class ThumbnailDiskCache: ThumbnailDiskCaching, @unchecked Sendable {
    static let retention: TimeInterval = 24 * 60 * 60
    static let byteLimit = 64 * 1024 * 1024
    static let directoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Switchly/Thumbnails", isDirectory: true)

    private let queue = DispatchQueue(label: "com.switchly.thumbnailDiskCache", qos: .utility)
    private let directory: URL
    private let byteLimit: Int
    private let now: () -> Date
    private let identity: (WindowInfo) -> ThumbnailDiskIdentity?

    init(
        directory: URL = ThumbnailDiskCache.directoryURL,
        byteLimit: Int = ThumbnailDiskCache.byteLimit,
        now: @escaping () -> Date = Date.init,
        identity: @escaping (WindowInfo) -> ThumbnailDiskIdentity? = ThumbnailDiskIdentity.resolve
    ) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.now = now
        self.identity = identity
        queue.async { [weak self] in self?.prune() }
    }

    func load(for window: WindowInfo) async -> PersistedThumbnail? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: autoreleasepool { self.read(window) })
            }
        }
    }

    func save(_ thumbnail: PersistedThumbnail, for window: WindowInfo) {
        // 排队时固定身份，写入时再次校验，拒绝排队期间退出或 PID 被复用的进程。
        guard let identity = identity(window) else { return }
        queue.async {
            autoreleasepool {
                self.write(thumbnail, identity: identity, window: window)
            }
        }
    }

    /// 仅退出时等待已经入队的写入，超时后继续退出，不等待尚未完成的系统截图。
    func flush(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private struct Record: Codable {
        let version: Int
        let key: String
        let capturedAt: Date
        let width: Int
        let height: Int
        let scale: Double
        let jpeg: Data
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("thumbnail")
    }

    private func read(_ window: WindowInfo) -> PersistedThumbnail? {
        guard let key = identity(window)?.key else { return nil }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.version == 1, record.key == key,
              isValid(record.capturedAt), record.width > 0, record.height > 0,
              record.width <= 1200, record.height <= 1200,
              record.scale.isFinite, record.scale > 0,
              let bitmap = NSBitmapImageRep(data: record.jpeg),
              bitmap.pixelsWide == record.width, bitmap.pixelsHigh == record.height,
              let cgImage = bitmap.cgImage else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // 读盘过程中目标进程或窗口身份改变时，不交付旧图。
        guard identity(window)?.key == key else { return nil }
        return PersistedThumbnail(
            image: NSImage(cgImage: cgImage, size: CGSize(
                width: Double(record.width) / record.scale,
                height: Double(record.height) / record.scale
            )),
            capturedAt: record.capturedAt,
            pixelSize: CGSize(width: record.width, height: record.height)
        )
    }

    private func write(_ thumbnail: PersistedThumbnail, identity: ThumbnailDiskIdentity, window: WindowInfo) {
        guard self.identity(window)?.key == identity.key, isValid(thumbnail.capturedAt),
              let source = thumbnail.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let fitted = ThumbnailService.fittedPixelSize(
            source: CGSize(width: source.width, height: source.height),
            into: CGSize(width: 1200, height: 1200)
        )
        guard let image = ThumbnailService.downsample(source, width: max(1, Int(fitted.width)), height: max(1, Int(fitted.height))),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        let scale = thumbnail.image.size.width > 0 ? Double(image.width) / thumbnail.image.size.width : 1
        let record = Record(version: 1, key: identity.key, capturedAt: thumbnail.capturedAt,
                            width: image.width, height: image.height, scale: scale, jpeg: jpeg)
        let url = fileURL(for: identity.key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // 异步任务可能乱序入队，旧截图不能覆盖较新的截图。
            if let data = try? Data(contentsOf: url),
               let existing = try? PropertyListDecoder().decode(Record.self, from: data),
               existing.capturedAt > thumbnail.capturedAt { return }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(record)
            if data.count <= byteLimit {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([
                    .posixPermissions: 0o600, .modificationDate: thumbnail.capturedAt
                ], ofItemAtPath: url.path)
            }
            prune()
        } catch {
            AppLogger.throttledWarning(key: "thumbnail-disk-write", "缩略图磁盘缓存写入失败")
        }
    }

    private func isValid(_ date: Date) -> Bool {
        let age = now().timeIntervalSince(date)
        return age >= 0 && age < Self.retention
    }

    /// 启动和写入时清理；读取也会单独拒绝、删除命中的过期文件。
    private func prune() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return }
        var files: [(url: URL, date: Date, bytes: Int)] = []
        for url in urls where url.pathExtension == "thumbnail" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard let date = values.contentModificationDate, isValid(date) else {
                try? manager.removeItem(at: url)
                continue
            }
            files.append((url, date, values.fileSize ?? 0))
        }
        var total = files.reduce(0) { $0 + $1.bytes }
        var count = files.count
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > byteLimit || count > TierBudget.grid.countLimit else { break }
            if (try? manager.removeItem(at: file.url)) != nil {
                total -= file.bytes
                count -= 1
            }
        }
    }
}
