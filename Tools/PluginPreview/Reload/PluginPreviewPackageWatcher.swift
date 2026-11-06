import Darwin
import Foundation

/// 监听整个插件包，合并连续保存；不会读取文件内容，也不使用轮询。
final class PluginPreviewPackageWatcher: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.switchly.preview.package-watcher")
    private let changed: @Sendable () -> Void
    private let queueKey = DispatchSpecificKey<Bool>()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var stopped = false

    init(directory: URL, changed: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.changed = changed
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() throws {
        try queue.sync {
            guard !stopped, sources.isEmpty else { return }
            try install()
        }
    }

    func stop() {
        let stopNow = { [self] in
            guard !stopped else { return }
            stopped = true
            pending?.cancel()
            pending = nil
            sources.forEach { $0.cancel() }
            sources.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { stopNow() }
        else { queue.sync(execute: stopNow) }
    }

    private func install() throws {
        _ = try PluginPackageValidator.load(directory: directory, origin: .user)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            throw PluginPreviewArtifactError.invalidPackage
        }
        // 父目录用于发现包目录被整体替换；不读取该目录中的其他内容。
        var paths = [directory.deletingLastPathComponent(), directory]
        for case let path as URL in enumerator {
            let values = try path.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true,
                  paths.count <= PluginPackageValidator.maxFiles else { throw PluginPreviewArtifactError.invalidPackage }
            paths.append(path)
        }
        var installed: [DispatchSourceFileSystemObject] = []
        do {
            for path in paths {
                let fd = open(path.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw PluginPreviewArtifactError.invalidPackage }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                    eventMask: [.write, .extend, .attrib, .link, .rename, .delete], queue: queue)
                source.setEventHandler { [weak self] in self?.schedule() }
                source.setCancelHandler { close(fd) }
                source.resume()
                installed.append(source)
            }
        } catch {
            installed.forEach { $0.cancel() }
            throw error
        }
        sources.forEach { $0.cancel() }
        sources = installed
    }

    private func schedule() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            // 先重新订阅新文件，再让控制器验证快照；失败仍通知界面标记 stale。
            try? self.install()
            self.changed()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    deinit { stop() }
}
