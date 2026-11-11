import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

protocol WindowCaptureDocumentServicing: AnyObject {
    func makeEditingFile(image: CGImage, sessionID: UUID) async throws -> URL
    func loadEditedImage(url: URL) async throws -> CGImage
    func save(image: CGImage, to url: URL) async throws
    func cleanup(sessionID: UUID) async
    func cleanupStale() async
    @MainActor func copy(image: CGImage) async throws
}

final class WindowCaptureDocumentService: WindowCaptureDocumentServicing {
    private let root: URL
    private let queue = DispatchQueue(label: "com.switchly.capture-files", qos: .userInitiated)
    // Confined to queue. Only paths created by this instance may be reloaded or removed.
    private var sessions: [UUID: URL] = [:]

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("com.switchly.window-capture")) {
        self.root = root
    }

    func makeEditingFile(image: CGImage, sessionID: UUID) async throws -> URL {
        try await io {
            let manager = FileManager.default
            if manager.fileExists(atPath: self.root.path) {
                let values = try self.root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { throw WindowCaptureFailure.invalidRequest }
            } else {
                try manager.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let directory = self.root.appendingPathComponent("window-capture-\(getpid())-\(sessionID.uuidString)")
            guard !manager.fileExists(atPath: directory.path) else { throw WindowCaptureFailure.busy }
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                let file = directory.appendingPathComponent("image.png")
                try Self.png(image).write(to: file, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                self.sessions[sessionID] = file
                return file
            } catch { try? manager.removeItem(at: directory); throw error }
        }
    }

    func loadEditedImage(url: URL) async throws -> CGImage {
        try await io {
            guard self.sessions.values.contains(url) else { throw WindowCaptureFailure.invalidRequest }
            let directory = try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let file = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard directory.isSymbolicLink != true, directory.isDirectory == true,
                  file.isSymbolicLink != true, file.isRegularFile == true,
                  let size = file.fileSize else { throw WindowCaptureFailure.invalidRequest }
            guard size <= WindowCaptureLimits.maxFileBytes else { throw WindowCaptureFailure.tooLarge }
            var result: Result<CGImage, Error> = .failure(WindowCaptureFailure.captureFailed)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
                result = Result {
                    let data = try Data(contentsOf: coordinated, options: .mappedIfSafe)
                    guard data.count <= WindowCaptureLimits.maxFileBytes else { throw WindowCaptureFailure.tooLarge }
                    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetType(source) as String? == UTType.png.identifier,
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                        throw WindowCaptureFailure.captureFailed
                    }
                    guard WindowCaptureLimits.accepts(width: width, height: height) else {
                        throw WindowCaptureFailure.tooLarge
                    }
                    guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                        throw WindowCaptureFailure.captureFailed
                    }
                    return image
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }
    }

    func save(image: CGImage, to url: URL) async throws {
        let cancellation = WriteCancellation()
        try await withTaskCancellationHandler(operation: {
            try await io {
                let data = try Self.png(image)
                try cancellation.check()
                try data.write(to: url, options: .atomic)
            }
        }, onCancel: { cancellation.cancel() })
    }

    @MainActor
    func copy(image: CGImage) async throws {
        let data = try await io { try Self.png(image) }
        try Task.checkCancellation()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(data, forType: .png) else { throw WindowCaptureFailure.captureFailed }
    }

    func cleanup(sessionID: UUID) async {
        _ = try? await io {
            if let file = self.sessions.removeValue(forKey: sessionID) {
                try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
        }
    }

    func cleanupStale() async {
        _ = try? await io {
            guard (try? self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return }
            let manager = FileManager.default
            let directories = try manager.contentsOfDirectory(at: self.root, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey])
            for directory in directories {
                let parts = directory.lastPathComponent.split(separator: "-", maxSplits: 3)
                guard parts.count == 4, parts[0] == "window", parts[1] == "capture",
                      let pid = Int32(parts[2]), pid > 0, UUID(uuidString: String(parts[3])) != nil,
                      !self.sessions.values.contains(where: { $0.deletingLastPathComponent() == directory }) else { continue }
                let values = try directory.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true,
                      let created = values.creationDate, Date().timeIntervalSince(created) > WindowCaptureLimits.staleFileAge,
                      kill(pid, 0) == -1, errno == ESRCH else { continue }
                try manager.removeItem(at: directory)
            }
        }
    }

    private static func png(_ image: CGImage) throws -> Data {
        guard WindowCaptureLimits.accepts(width: image.width, height: image.height) else { throw WindowCaptureFailure.tooLarge }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WindowCaptureFailure.captureFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= WindowCaptureLimits.maxFileBytes else { throw WindowCaptureFailure.tooLarge }
        return data as Data
    }

    private func io<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private final class WriteCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let cancelled = cancelled; lock.unlock()
            if cancelled { throw CancellationError() }
        }
    }
}
