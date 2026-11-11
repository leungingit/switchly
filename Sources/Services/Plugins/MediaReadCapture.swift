import Foundation

extension MediaBridging {
    /// 默认桥和 Preview fixture 共用有界夹取，不会创建 Adapter。
    func frozenRead(bundleID: String) throws -> MediaReadContext {
        if let provider = self as? MediaReadProviding { return try provider.readContext(bundleID: bundleID) }
        let before = try nowPlaying(bundleID: bundleID)
        let bytes = before == nil ? nil : try artwork(bundleID: bundleID)
        let after = try nowPlaying(bundleID: bundleID)
        let matched = MediaReadContext.sameTrack(before, after)
        let data = matched ? bytes : nil
        return MediaReadContext(nowPlaying: after, artwork: data.flatMap { MediaArtworkDecoder.decode($0) },
                                artworkToken: data.map {
                                    let identity = [after?.trackID ?? "", after?.title ?? "", after?.artist ?? "", after?.album ?? ""]
                                    let identityData = (try? JSONSerialization.data(withJSONObject: identity)) ?? Data()
                                    return "appleScript:" + MediaReadContext.imageToken(identityData) + ":" + MediaReadContext.imageToken($0)
                                }) { [weak self] in
            guard let self, let latest = try? self.nowPlaying(bundleID: bundleID) else { return after == nil }
            return MediaReadContext.sameTrack(after, latest) && after?.liked == latest.liked && after?.isPlaying == latest.isPlaying
        }
    }
}
