import AppKit
import Foundation

/// 宿主的组合读取桥；来源选择与系统依赖装配分离。
/// 所有脚本和资料库操作沿用同一串行队列和 AppleScript 授权/播放状态协调。
final class CompositeMediaBridge: MediaReadProviding, MusicLibraryPlaying, @unchecked Sendable {
    let queue: DispatchQueue
    private let script: MediaBridging & MusicLibraryPlaying
    private let session: MediaRemoteSession
    private let identity: () -> MediaRemoteProcessIdentity?

    init(script: MediaBridging & MusicLibraryPlaying, session: MediaRemoteSession,
         identity: @escaping () -> MediaRemoteProcessIdentity?) {
        self.script = script
        self.session = session
        self.identity = identity
        queue = script.queue
    }

    func supports(bundleID: String) -> Bool { script.supports(bundleID: bundleID) }
    func acquireReadInterest(invalidate: @escaping () -> Void) -> MediaReadInterest {
        session.acquire(invalidate: invalidate)
    }

    func readContext(bundleID: String) throws -> MediaReadContext {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        let process = identity()
        let before = try script.nowPlaying(bundleID: bundleID)
        let (candidate, image, epoch) = session.snapshot()
        var fallbackBefore = before
        if let process, let before, let candidate {
            let after = try script.nowPlaying(bundleID: bundleID)
            fallbackBefore = after
            let current = session.snapshot().0
            if let after, let current,
               MediaRemotePairing.matches(candidate, before: MusicMediaSample(process: process, nowPlaying: before),
                                          after: MusicMediaSample(process: identity() ?? process, nowPlaying: after),
                                          currentToken: current.token), identity() == process {
                let remote = candidate.nowPlaying
                var playing = NowPlaying(isPlaying: after.isPlaying, title: remote.title, artist: remote.artist,
                                         album: remote.album, position: remote.position, duration: remote.duration,
                                         liked: after.liked, canLike: after.canLike)
                playing.trackID = after.trackID
                let read = MediaReadContext(nowPlaying: playing, source: .mediaRemote, artwork: image, artworkToken: candidate.artworkToken,
                                            validateFreshness: { [weak self] in self?.session.isCurrent(epoch) == true },
                                            validateArtwork: { [weak self] in
                    self?.session.isArtworkCurrent(candidate.artworkToken) == true
                }) { [weak self] in
                    guard let self, self.session.isCurrent(epoch), self.identity() == process,
                          let latest = try? self.script.nowPlaying(bundleID: bundleID) else { return false }
                    return MediaReadContext.sameTrack(after, latest) && latest.liked == after.liked && latest.isPlaying == after.isPlaying
                }
                return read
            }
        }
        // 整组回退：授权失败、来源不符和配对歧义不拼接系统图片。
        let fallback = try script.frozenRead(bundleID: bundleID, before: fallbackBefore)
        let read = MediaReadContext(nowPlaying: fallback.nowPlaying, artwork: fallback.artwork,
                                    artworkToken: fallback.artworkToken,
                                    validateFreshness: { [weak self] in self?.session.isCurrent(epoch) == true }) { [weak self] in
            guard let self else { return false }
            return self.identity() == process && self.session.isCurrent(epoch) && fallback.isCurrent()
        }
        return read
    }

    func nowPlaying(bundleID: String) throws -> NowPlaying? { try readContext(bundleID: bundleID).nowPlaying }
    func artwork(bundleID: String) throws -> Data? {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        return try readContext(bundleID: bundleID).artwork?.tiffRepresentation
    }

    func perform(_ command: MediaCommand, bundleID: String) throws {
        if command == .next || command == .previous { session.willChangeTrack(allowRestart: command == .previous) }
        defer { session.invalidateReaders() }
        try script.perform(command, bundleID: bundleID)
    }
    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
        try script.pickRandomTrack(genreKeywords: genreKeywords)
    }
    func play(persistentID: String) throws {
        session.willChangeTrack()
        defer { session.invalidateReaders() }
        try script.play(persistentID: persistentID)
    }
    func pausePlayback() throws {
        defer { session.invalidateReaders() }
        try script.pausePlayback()
    }
    func currentTrack() throws -> NowPlaying? { try script.currentTrack() }
}
