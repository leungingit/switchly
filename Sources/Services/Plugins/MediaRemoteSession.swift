import AppKit
import Foundation

/// 状态归并由串行队列拥有；短锁仅保护可供展示端立即读取的缓存。
/// 一个组合桥共享一条流，解码最多一个在途工作和一个最新候选。
final class MediaRemoteSession: @unchecked Sendable {
    private let lock = NSLock()
    private let lifecycle = DispatchQueue(label: "com.switchly.mediaremote.lifecycle")
    private let updates = DispatchQueue(label: "com.switchly.mediaremote.state")
    private let decoding = DispatchQueue(label: "com.switchly.mediaremote.artwork", qos: .utility)
    private let stream: MediaRemoteStream
    private let decodeArtwork: (Data) -> NSImage?
    private let identity: () -> MediaRemoteProcessIdentity?
    // 以下可变状态只在 updates 队列访问，不在锁内解析 Base64 或计算摘要。
    private var state = MediaRemoteState()
    private var streamTarget: MediaRemoteProcessIdentity?
    private var observers: [UUID: PluginInvalidator] = [:]
    private var cycle: UUID?
    private var connection: UUID?
    private var suspended = false
    private var epoch: UInt64 = 0
    private var image: NSImage?
    private var imageToken: String?
    private var history = MediaArtworkHistory()
    private var pending: (Data, String)?
    private var decodingActive = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cached: (snapshot: MediaRemoteSnapshot?, image: NSImage?, epoch: UInt64, uptime: TimeInterval) =
        (nil, nil, 0, 0)

    init(stream: MediaRemoteStream, identity: @escaping () -> MediaRemoteProcessIdentity?,
         observeWorkspace: Bool = true, decodeArtwork: @escaping (Data) -> NSImage? = MediaArtworkDecoder.decode) {
        self.stream = stream
        self.identity = identity
        self.decodeArtwork = decodeArtwork
        if observeWorkspace {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers = [center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.setSleeping(true)
            }, center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.setSleeping(false)
            }, center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                self?.targetChanged()
            }, center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                self?.targetChanged()
            }]
        }
    }

    func acquire(invalidate: @escaping () -> Void) -> MediaReadInterest {
        let id = UUID()
        lifecycle.async { [self] in
            let start = updates.sync { () -> Bool in
                observers[id] = PluginInvalidator(invalidate)
                return observers.count == 1 && !suspended
            }
            if start { startStream() }
        }
        return MediaReadInterest { [weak self] in
            guard let self else { return }
            self.lifecycle.async {
                let stop = self.updates.sync { () -> Bool in
                    self.observers.removeValue(forKey: id)?.cancel()
                    return self.observers.isEmpty
                }
                if stop { self.stopStream() }
            }
        }
    }

    func setSleeping(_ sleeping: Bool) {
        lifecycle.async { [self] in
            let result = updates.sync { () -> (Bool, Bool) in
                let changed = suspended != sleeping
                suspended = sleeping
                return (changed, !sleeping && !observers.isEmpty)
            }
            guard result.0 else { return }
            stopStream()
            if result.1 { startStream() }
        }
    }

    private func targetChanged() {
        lifecycle.async { [self] in
            let target = identity()
            let result = updates.sync { () -> (Bool, Bool) in
                guard streamTarget != target else { return (false, false) }
                return (true, !observers.isEmpty && !suspended)
            }
            guard result.0 else { return }
            stopStream()
            if result.1 { startStream() }
        }
    }

    private func startStream() {
        let cycle = UUID()
        let target = identity()
        updates.sync {
            streamTarget = target
            self.cycle = cycle
            connection = nil
            state.begin(connection: UUID(), target: target)
            publish()
        }
        _ = stream.start { [weak self] event in self?.receive(event, cycle: cycle) }
    }

    private func stopStream() {
        updates.sync {
            cycle = nil
            connection = nil
            state.invalidate()
            history.removeAll()
            clearImage()
            publish()
        }
        stream.stop()
    }

    private func receive(_ event: MediaRemoteStreamEvent, cycle: UUID) {
        let target = identity()
        // 同步交接维持 stdout 背压；展示端从不等待此队列。
        updates.sync {
            guard self.cycle == cycle else { return }
            switch event {
            case .data(let id, let event):
                if connection != id {
                    connection = id
                    history.removeAll()
                    clearImage()
                    state.begin(connection: id, target: target)
                }
                if streamTarget != target {
                    history.removeAll()
                    streamTarget = target
                }
                state.updateTarget(target)
                do { try state.apply(event, connection: id, wallTime: Date(), uptime: ProcessInfo.processInfo.systemUptime) }
                catch { state.invalidate() }
                if event.fields[.artworkData] != nil, state.snapshot?.artwork == nil {
                    if let snapshot = state.snapshot, let key = MediaArtworkHistory.key(snapshot) {
                        history.remove(key)
                    } else { history.removeAll() }
                }
            case .failed: state.invalidate()
            case .diagnostic: return
            }
            if state.snapshot == nil && state.selection != .awaitingTrackChange { history.removeAll() }
            let token = state.snapshot?.artworkToken
            if token != imageToken { image = nil; imageToken = nil }
            if let data = state.snapshot?.artwork, let token {
                if token != imageToken {
                    let key = state.snapshot.flatMap(MediaArtworkHistory.key)
                    if let key, let entry = history.take(key), token.hasSuffix(":" + entry.digest) {
                        image = entry.image
                        imageToken = token
                        pending = nil
                    } else {
                        if let key { history.remove(key) }
                        pending = (data, token)
                        if !decodingActive {
                            decodingActive = true
                            decoding.async { [weak self] in self?.decodePending() }
                        }
                    }
                } else { pending = nil }
            } else {
                pending = nil
                if let snapshot = state.snapshot, let key = MediaArtworkHistory.key(snapshot),
                   let entry = history.take(key) {
                    image = entry.image
                    imageToken = "\(snapshot.token.connection):\(snapshot.token.track):\(entry.digest)"
                }
            }
            publish()
        }
    }

    private func decodePending() {
        while true {
            let work = updates.sync { () -> (Data, String)? in
                guard let work = pending else { decodingActive = false; return nil }
                pending = nil
                return work
            }
            guard let work else { return }
            let decoded = decodeArtwork(work.0)
            updates.sync {
                guard state.snapshot?.artworkToken == work.1, cycle != nil else { return }
                image = decoded
                imageToken = decoded == nil ? nil : work.1
                if let snapshot = state.snapshot, let key = MediaArtworkHistory.key(snapshot) {
                    if let decoded {
                        history.insert(decoded, digest: String(work.1.split(separator: ":").last ?? ""), key: key)
                    } else { history.remove(key) }
                }
                publish()
            }
        }
    }

    private func clearImage() { image = nil; imageToken = nil; pending = nil }

    /// 只在 updates 队列调用。缓存替换后再释放旧图/快照，锁内不执行析构和回调。
    private func publish() {
        epoch &+= 1
        let uptime = ProcessInfo.processInfo.systemUptime
        let next = (displaySnapshot(at: uptime), image, epoch, uptime)
        lock.lock()
        let old = cached
        cached = next
        lock.unlock()
        withExtendedLifetime(old) {}
        observers.values.forEach { $0.invalidate() }
    }

    private func displaySnapshot(at uptime: TimeInterval) -> MediaRemoteSnapshot? {
        guard let snapshot = state.snapshot(at: uptime) else { return nil }
        return MediaRemoteSnapshot(token: snapshot.token, process: snapshot.process, nowPlaying: snapshot.nowPlaying,
                                   artwork: snapshot.artwork, artworkToken: imageToken ?? snapshot.artworkToken,
                                   hasNativeIdentity: snapshot.hasNativeIdentity, isAmbiguous: snapshot.isAmbiguous,
                                   playbackRate: snapshot.playbackRate)
    }

    func invalidateReaders() { updates.sync { publish() } }

    func willChangeTrack(allowRestart: Bool = false) {
        updates.sync { state.willChangeTrack(allowRestart: allowRestart, uptime: ProcessInfo.processInfo.systemUptime); clearImage(); publish() }
    }

    /// 缓存读取只复制引用，进度在锁外按单调时间推算，不查询运行进程或执行脚本。
    func snapshot() -> (MediaRemoteSnapshot?, NSImage?, UInt64) {
        lock.lock()
        let value = cached
        lock.unlock()
        guard let snapshot = value.snapshot else { return (nil, value.image, value.epoch) }
        let old = snapshot.nowPlaying
        var playing = NowPlaying(isPlaying: old.isPlaying, title: old.title, artist: old.artist, album: old.album,
                                 position: min(old.duration, old.position + (max(0, ProcessInfo.processInfo.systemUptime - value.uptime) * snapshot.playbackRate)),
                                 duration: old.duration, liked: old.liked, canLike: old.canLike)
        playing.trackID = old.trackID
        return (MediaRemoteSnapshot(token: snapshot.token, process: snapshot.process, nowPlaying: playing,
                                    artwork: snapshot.artwork, artworkToken: snapshot.artworkToken,
                                    hasNativeIdentity: snapshot.hasNativeIdentity, isAmbiguous: snapshot.isAmbiguous, playbackRate: snapshot.playbackRate), value.image, value.epoch)
    }

    func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached.epoch == revision
    }

    func isArtworkCurrent(_ token: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached.snapshot?.artworkToken == token
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        stream.stop()
    }
}
