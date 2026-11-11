import CryptoKit
import Foundation

struct MediaRemoteProcessIdentity: Equatable {
    let pid: Int32
    let launchDate: Date
}

struct MediaRemoteToken: Equatable {
    let connection: UUID
    let track: UInt64
    let revision: UInt64
}

struct MediaRemoteSnapshot {
    let token: MediaRemoteToken
    let process: MediaRemoteProcessIdentity
    let nowPlaying: NowPlaying
    let artwork: Data?
    let artworkToken: String?
    let hasNativeIdentity: Bool
    let isAmbiguous: Bool
    var playbackRate: Double = 1
}

enum MediaRemoteSelection: Equatable {
    case awaitingFullSnapshot, awaitingTrackChange, noTarget, noSession, sourceMismatch, invalidIdentity, invalidMetadata, ready
}

/// 由调用方的串行队列拥有。只生成候选快照，不执行脚本、解码图片或连接默认媒体桥。
struct MediaRemoteState {
    private(set) var connection = UUID()
    private(set) var selection: MediaRemoteSelection = .awaitingFullSnapshot
    private(set) var snapshot: MediaRemoteSnapshot?
    private(set) var rejectedArtwork = false
    private var target: MediaRemoteProcessIdentity?
    private var fields: [MediaRemoteField: MediaRemoteValue] = [:]
    private var receivedFull = false
    private var track: UInt64 = 0
    private var revision: UInt64 = 0
    private var trackKey: [String]?
    private var ambiguous = false
    private var awaitingDifferentTrack: [String]?
    private var restartPosition: Double?
    private var progressAnchor: (position: Double, rate: Double, uptime: TimeInterval)?
    static let bundleID = "com.apple.Music"

    init(target: MediaRemoteProcessIdentity? = nil) { self.target = target }

    mutating func begin(connection: UUID, target: MediaRemoteProcessIdentity?) {
        self = Self(target: target)
        self.connection = connection
    }

    mutating func invalidate() {
        begin(connection: UUID(), target: target)
    }

    /// 目标退出或 PID 被复用后，即使进程号相同也撤销旧连接的全部资格。
    mutating func updateTarget(_ identity: MediaRemoteProcessIdentity?) {
        guard target != identity else { return }
        begin(connection: UUID(), target: identity)
    }

    func isCurrent(_ token: MediaRemoteToken) -> Bool { snapshot?.token == token }

    /// 控制请求发出即撤图；previous 仅可由明确的同曲回到开头事件解除屏障。
    mutating func willChangeTrack(allowRestart: Bool = false, uptime: TimeInterval? = nil) {
        restartPosition = allowRestart ? (uptime.flatMap { snapshot(at: $0) } ?? snapshot)?.nowPlaying.position : nil
        awaitingDifferentTrack = trackKey
        snapshot = nil
        fields.removeValue(forKey: .artworkData)
        fields.removeValue(forKey: .artworkMimeType)
        selection = .awaitingTrackChange
        revision += 1
    }

    mutating func apply(_ event: MediaRemoteEvent, connection: UUID,
                        wallTime: Date, uptime: TimeInterval) throws {
        guard connection == self.connection else { return }
        guard !event.isDiff || receivedFull else { throw MediaRemoteFailure.missingFullSnapshot }
        if !event.isDiff { fields.removeAll(); receivedFull = true }
        for (key, value) in event.fields {
            if value == .null { fields.removeValue(forKey: key) }
            else { fields[key] = value }
        }
        revision += 1
        let previous = snapshot
        snapshot = nil
        rejectedArtwork = false
        guard let target else { clear(.noTarget); return }
        guard !fields.isEmpty else { clear(.noSession); return }
        guard fields[.bundleIdentifier]?.string == Self.bundleID else { clear(.sourceMismatch); return }
        guard fields[.processIdentifier]?.number == Double(target.pid), target.pid > 0 else {
            clear(.invalidIdentity); return
        }
        guard let title = fields[.title]?.string, !title.isEmpty,
              let playing = fields[.playing]?.bool else { clear(.invalidMetadata); return }
        let artist = fields[.artist]?.string ?? ""
        let album = fields[.album]?.string ?? ""
        let native = [fields[.uniqueIdentifier]?.string ?? "", fields[.contentItemIdentifier]?.string ?? ""]
        let key = native + [title, artist, album]
        let elapsedReset = event.fields[.elapsedTime]?.number
        let restarted = awaitingDifferentTrack == key && restartPosition.map { old in
            elapsedReset.map { $0 >= 0 && $0 <= 2 && old > 2 && old - $0 >= 1 } ?? false
        } == true
        if awaitingDifferentTrack == key && !restarted {
            fields.removeValue(forKey: .artworkData)
            fields.removeValue(forKey: .artworkMimeType)
            selection = .awaitingTrackChange
            return
        }
        awaitingDifferentTrack = nil
        restartPosition = nil
        if restarted {
            track += 1
            progressAnchor = nil
            if event.fields[.timestamp] == nil { fields.removeValue(forKey: .timestamp) }
        }
        if key != trackKey {
            let sameMetadata = trackKey.map { Array($0.suffix(3)) == [title, artist, album] } ?? false
            ambiguous = sameMetadata && trackKey != nil
            track += 1
            trackKey = key
            progressAnchor = nil
            // 只有本次事件明确给出的图片才可能属于新歌。
            if event.fields[.artworkData] == nil { fields.removeValue(forKey: .artworkData) }
            if event.fields[.artworkMimeType] == nil { fields.removeValue(forKey: .artworkMimeType) }
        }
        let duration = max(0, fields[.duration]?.number ?? 0)
        let elapsed = max(0, fields[.elapsedTime]?.number ?? 0)
        let rate = playing ? max(0, fields[.playbackRate]?.number ?? 1) : 0
        let timingChanged = !event.isDiff || progressAnchor == nil ||
            [.elapsedTime, .timestamp, .playbackRate, .playing].contains { event.fields[$0] != nil }
        if timingChanged {
            var position = elapsed
            if let timestamp = fields[.timestamp]?.string,
               let date = ISO8601DateFormatter().date(from: timestamp) {
                let age = wallTime.timeIntervalSince(date)
                if age >= 0 && age <= 3600 { position += age * rate }
            }
            // 暂停事件若没有位置字段，冻结此前单调时钟推算值。
            if event.isDiff, event.fields[.elapsedTime] == nil, event.fields[.timestamp] == nil,
               let anchor = progressAnchor {
                position = anchor.position + max(0, uptime - anchor.uptime) * anchor.rate
            }
            progressAnchor = (position, rate, uptime)
        }
        let anchor = progressAnchor!
        let position = min(duration, max(0, anchor.position + max(0, uptime - anchor.uptime) * anchor.rate))
        var np = NowPlaying(isPlaying: playing, title: title, artist: artist, album: album,
                            position: position, duration: duration, liked: false, canLike: false)
        np.trackID = native.joined(separator: ":")
        var artwork: Data?
        if event.isDiff, event.fields[.artworkData] == nil, fields[.artworkData] != nil,
           previous?.token.track == track {
            artwork = previous?.artwork
        } else if let encoded = fields[.artworkData]?.string {
            if encoded.utf8.count <= ((MediaRemoteBudget.artworkBytes + 2) / 3) * 4,
               let data = Data(base64Encoded: encoded), !data.isEmpty,
               data.count <= MediaRemoteBudget.artworkBytes {
                artwork = data
            } else {
                rejectedArtwork = true
                fields.removeValue(forKey: .artworkData)
            }
        }
        // 进度增量不重复计算已有图片的内容摘要。
        let artworkToken: String?
        if let artwork {
            if previous?.token.track == track, previous?.artwork == artwork {
                artworkToken = previous?.artworkToken
            } else {
                artworkToken = "\(connection.uuidString):\(track):" +
                    SHA256.hash(data: artwork).map { String(format: "%02x", $0) }.joined()
            }
        } else { artworkToken = nil }
        selection = .ready
        snapshot = MediaRemoteSnapshot(token: MediaRemoteToken(connection: connection, track: track, revision: revision),
                                       process: target, nowPlaying: np, artwork: artwork,
                                       artworkToken: artworkToken,
                                       hasNativeIdentity: native.contains { !$0.isEmpty }, isAmbiguous: ambiguous, playbackRate: rate)
    }

    func snapshot(at uptime: TimeInterval) -> MediaRemoteSnapshot? {
        guard let snapshot, let anchor = progressAnchor else { return snapshot }
        let old = snapshot.nowPlaying
        var playing = NowPlaying(isPlaying: old.isPlaying, title: old.title, artist: old.artist, album: old.album,
                                 position: min(old.duration, max(0, anchor.position + max(0, uptime - anchor.uptime) * anchor.rate)),
                                 duration: old.duration, liked: old.liked, canLike: old.canLike)
        playing.trackID = old.trackID
        return MediaRemoteSnapshot(token: snapshot.token, process: snapshot.process, nowPlaying: playing,
                                   artwork: snapshot.artwork, artworkToken: snapshot.artworkToken,
                                   hasNativeIdentity: snapshot.hasNativeIdentity, isAmbiguous: snapshot.isAmbiguous, playbackRate: snapshot.playbackRate)
    }

    private mutating func clear(_ reason: MediaRemoteSelection) {
        selection = reason
        fields.removeValue(forKey: .artworkData)
        fields.removeValue(forKey: .artworkMimeType)
        trackKey = nil
        progressAnchor = nil
        ambiguous = false
        awaitingDifferentTrack = nil
        restartPosition = nil
        track += 1
    }
}

struct MusicMediaSample {
    let process: MediaRemoteProcessIdentity
    let nowPlaying: NowPlaying
}

enum MediaRemotePairing {
    /// 有界一致性检查；不宣称它是跨来源歌曲 ID 的权威映射。
    static func matches(_ snapshot: MediaRemoteSnapshot, before: MusicMediaSample,
                        after: MusicMediaSample, currentToken: MediaRemoteToken,
                        knownAmbiguous: Bool = false) -> Bool {
        let a = before.nowPlaying, b = after.nowPlaying, media = snapshot.nowPlaying
        guard snapshot.token == currentToken, snapshot.hasNativeIdentity,
              !snapshot.isAmbiguous, !knownAmbiguous,
              before.process == snapshot.process, after.process == snapshot.process,
              !a.trackID.isEmpty, a.trackID == b.trackID,
              [a.title, a.artist, a.album].allSatisfy({ !$0.isEmpty }),
              a.title == b.title, a.artist == b.artist, a.album == b.album,
              a.title == media.title, a.artist == media.artist, a.album == media.album,
              a.duration.isFinite, b.duration.isFinite, media.duration.isFinite,
              a.duration > 0, b.duration > 0, media.duration > 0,
              abs(a.duration - b.duration) <= 1, abs(a.duration - media.duration) <= 1,
              abs(b.duration - media.duration) <= 1 else { return false }
        return true
    }
}
