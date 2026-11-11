import AppKit
import CryptoKit

/// 一批 render 固定的数据组。内部身份和图片不进入 JS。
final class MediaReadContext: @unchecked Sendable {
    enum Source: String { case appleScript, mediaRemote, fixture, unavailable }
    let source: Source
    let readError: String?
    let requiresAuthorization: Bool
    let nowPlaying: NowPlaying?
    let artwork: NSImage?
    let artworkToken: String?
    private let validate: () -> Bool
    private let validateArtwork: () -> Bool
    private let validateFreshness: () -> Bool

    init(nowPlaying: NowPlaying?, source: Source = .appleScript, readError: String? = nil, requiresAuthorization: Bool = true, artwork: NSImage?, artworkToken: String?, validateFreshness: @escaping () -> Bool = { true }, validateArtwork: @escaping () -> Bool = { false }, validate: @escaping () -> Bool) {
        self.nowPlaying = nowPlaying
        self.source = source
        self.readError = readError
        self.requiresAuthorization = requiresAuthorization
        self.artwork = artwork
        self.artworkToken = artwork == nil ? nil : artworkToken
        self.validate = validate
        self.validateArtwork = validateArtwork
        self.validateFreshness = validateFreshness
    }

    /// 在媒体桥串行队列调用；可以重新采样 AppleScript。
    func isCurrent() -> Bool { validate() }
    func isFresh() -> Bool { validateFreshness() }
    func artworkIsCurrent() -> Bool { validateArtwork() }

    static func sameTrack(_ a: NowPlaying?, _ b: NowPlaying?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.trackID == b.trackID && a.title == b.title && a.artist == b.artist && a.album == b.album
    }

    static func imageToken(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 媒体兴趣沿用宿主通用的生命周期句柄。
typealias MediaReadInterest = PluginLifetime

protocol MediaReadProviding: MediaBridging {
    func readContext(bundleID: String) throws -> MediaReadContext
    func acquireReadInterest(invalidate: @escaping () -> Void) -> MediaReadInterest
}
