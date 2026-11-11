import AppKit

/// 由 Session 的状态队列独占；只缓存已解码位图，不保留播放器的动态状态。
struct MediaArtworkHistory {
    static let maxEntries = 8
    static let maxBytes = 8 * MediaArtworkDecoder.Budget.maxDecodedBytes

    struct Key {
        let identity: [String]
        let duration: Double

        func matches(_ other: Key) -> Bool {
            identity == other.identity && abs(duration - other.duration) <= 1
        }
    }

    struct Entry {
        let key: Key
        let image: NSImage
        let digest: String
        let bytes: Int
    }

    private(set) var entries: [Entry] = []
    var bytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    static func key(_ snapshot: MediaRemoteSnapshot) -> Key? {
        let song = snapshot.nowPlaying
        guard snapshot.hasNativeIdentity, !snapshot.isAmbiguous,
              !song.trackID.isEmpty, [song.title, song.artist, song.album].allSatisfy({ !$0.isEmpty }),
              song.duration.isFinite, song.duration > 0 else { return nil }
        return Key(identity: [song.trackID, song.title, song.artist, song.album], duration: song.duration)
    }

    mutating func take(_ key: Key) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.key.matches(key) }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }

    mutating func remove(_ key: Key) { entries.removeAll { $0.key.matches(key) } }
    mutating func removeAll() { entries.removeAll() }

    mutating func insert(_ image: NSImage, digest: String, key: Key) {
        remove(key)
        guard image.representations.count == 1,
              let bitmap = image.representations.first as? NSBitmapImageRep else { return }
        let (cost, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.pixelsHigh)
        guard !overflow, cost > 0, cost <= MediaArtworkDecoder.Budget.maxDecodedBytes else { return }
        entries.append(Entry(key: key, image: image, digest: digest, bytes: cost))
        while entries.count > Self.maxEntries || bytes > Self.maxBytes { entries.removeFirst() }
    }
}
