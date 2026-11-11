//
//  MediaBridge.swift
//  Switchly
//
//  Capability bridge behind ctx.media (design doc §4.1). Only fixed,
//  host-owned AppleScript is ever executed — plugins choose a command, never
//  a script. Measured on macOS 27 / Music: state, metadata, favorited
//  read/write, playpause / next / previous all work; "no current track"
//  surfaces as error -1728.
//

import AppKit
import Foundation

struct NowPlaying: Equatable {
    var trackID: String = ""
    let isPlaying: Bool
    let title: String
    let artist: String
    let album: String
    let position: Double
    let duration: Double
    let liked: Bool
    let canLike: Bool

    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }

    func withPlaying(_ newValue: Bool) -> NowPlaying {
        var updated = NowPlaying(isPlaying: newValue, title: title, artist: artist, album: album,
                                 position: position, duration: duration, liked: liked, canLike: canLike)
        updated.trackID = trackID
        return updated
    }

    var jsObject: [String: Any] {
        ["playing": isPlaying, "title": title, "artist": artist, "album": album, "position": position,
         "duration": duration, "progress": progress, "liked": liked, "canLike": canLike]
    }
}

/// Music applies `playpause` asynchronously: `player state` can keep reporting
/// the old value for a short moment afterwards. A toggle records the state it
/// requested, and `nowPlaying()` publishes it until Music catches up. The
/// deadline bounds the optimism, so a command that never took effect cannot
/// fake a state forever. Pure so the reconciliation is unit-testable without
/// sending Apple Events.
struct MediaPlayStateExpectation {
    let isPlaying: Bool
    let deadline: DispatchTime
}

enum MediaPlayStateReconciler {
    /// Returns the snapshot to publish and the expectation to keep (nil once
    /// Music agrees, the deadline has passed, or no toggle is pending).
    static func resolve(snapshot: NowPlaying?,
                        last: NowPlaying?,
                        expectation: MediaPlayStateExpectation?,
                        now: DispatchTime) -> (snapshot: NowPlaying?, expectation: MediaPlayStateExpectation?) {
        guard let expectation, now <= expectation.deadline,
              snapshot?.isPlaying != expectation.isPlaying else { return (snapshot, nil) }
        // A stopped app can briefly report no current track at all; keep the
        // last known track's metadata while the transport icon settles.
        guard let base = snapshot ?? last else { return (snapshot, expectation) }
        return (base.withPlaying(expectation.isPlaying), expectation)
    }
}

enum MediaCommand: String {
    case togglePlayPause
    case next
    case previous
    case like
    case unlike
}

enum MediaBridgeError: Error, Equatable {
    case unsupportedApp
    case notAuthorized
    case notRunning
    case scriptFailed(Int)
}

struct PickedTrack: Equatable {
    let persistentID: String
    let title: String
    let artist: String
    /// Beats per minute from the library; 0 when unknown.
    let bpm: Double
    /// False when no track matched the keywords and a random one was picked instead.
    let matchedGenre: Bool

    var jsObject: [String: Any] {
        ["persistentID": persistentID, "title": title, "artist": artist, "bpm": bpm, "matchedGenre": matchedGenre]
    }
}

/// Picks and plays library tracks; behind `ctx.media.library` for plugins
/// holding the `media.library` permission.
protocol MusicLibraryPlaying: AnyObject, Sendable {
    /// Serial queue every call must run on.
    var queue: DispatchQueue { get }
    /// A random track whose genre contains one of `genreKeywords`, else any
    /// random library track. nil when the library has no tracks. Does not play.
    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack?
    func play(persistentID: String) throws
    func pausePlayback() throws
    /// nil when nothing is loaded (stopped) or Music is not running.
    func currentTrack() throws -> NowPlaying?
}

protocol MediaBridging: AnyObject, Sendable {
    /// Serial queue every call must run on.
    var queue: DispatchQueue { get }
    func supports(bundleID: String) -> Bool
    /// nil when the app is not running, has no current track, or automation
    /// consent has not been granted yet. Never launches the target app.
    func nowPlaying(bundleID: String) throws -> NowPlaying?
    func perform(_ command: MediaCommand, bundleID: String) throws
    /// Encoded cover image of the current track, if any. Host-only: the bytes
    /// are drawn by Switchly and never handed to plugin JS.
    func artwork(bundleID: String) throws -> Data?
}

/// Apple Music via NSAppleScript. NSAppleScript is not thread-safe, so every
/// script runs on `queue`; callers use the async wrappers.
final class MusicAppleScriptBridge: MediaBridging, MusicLibraryPlaying, @unchecked Sendable {
    static let musicBundleID = "com.apple.Music"

    let queue = DispatchQueue(label: "com.switchly.plugin.media")
    private var compiled: [String: NSAppleScript] = [:]
    private var consentRequested = false
    /// Artwork of the last seen track; fetched again only when the track changes.
    /// `nil` data is cached only for streaming tracks, whose cover is never used.
    private var artworkCache: (track: NowPlaying, data: Data?)?
    /// State requested by the last `playpause`, kept until Music reports it.
    private var playStateExpectation: MediaPlayStateExpectation?
    /// Last successful snapshot; used when Music briefly reports no track.
    private var lastNowPlaying: NowPlaying?
    private let isRunning: (String) -> Bool

    init(isRunning: @escaping (String) -> Bool = { bundleID in
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }) {
        self.isRunning = isRunning
    }

    func supports(bundleID: String) -> Bool { bundleID == Self.musicBundleID }

    func nowPlaying(bundleID: String) throws -> NowPlaying? {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        guard isRunning(bundleID), ensureConsent(bundleID: bundleID) else { return nil }
        let script = """
        tell application id "\(bundleID)"
          if player state is stopped then return {}
          set t to current track
          return {(player state is playing), name of t, artist of t, album of t, player position, duration of t, favorited of t, persistent ID of t}
        end tell
        """
        let snapshot: NowPlaying?
        do {
            guard let result = try run(script), result.numberOfItems == 8 else {
                return reconcile(nil)
            }
            func item(_ i: Int) -> NSAppleEventDescriptor? { result.atIndex(i) }
            var playing = NowPlaying(
                isPlaying: item(1)?.booleanValue ?? false,
                title: item(2)?.stringValue ?? "",
                artist: item(3)?.stringValue ?? "",
                album: item(4)?.stringValue ?? "",
                position: item(5).flatMap(Self.double) ?? 0,
                duration: item(6).flatMap(Self.double) ?? 0,
                liked: item(7)?.booleanValue ?? false,
                canLike: true
            )
            playing.trackID = item(8)?.stringValue ?? ""
            snapshot = playing
        } catch MediaBridgeError.scriptFailed(-1728) {
            return reconcile(nil)  // no current track
        }
        return reconcile(snapshot)
    }

    /// Applies the pending toggle's requested state to a fresh snapshot. All
    /// callers run on `queue`, so the expectation and last snapshot stay
    /// confined to that serial queue.
    private func reconcile(_ snapshot: NowPlaying?) -> NowPlaying? {
        let resolved = MediaPlayStateReconciler.resolve(snapshot: snapshot,
                                                        last: lastNowPlaying,
                                                        expectation: playStateExpectation,
                                                        now: .now())
        if let snapshot { lastNowPlaying = snapshot }
        playStateExpectation = resolved.expectation
        return resolved.snapshot
    }

    func perform(_ command: MediaCommand, bundleID: String) throws {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        guard isRunning(bundleID) else { return }
        guard ensureConsent(bundleID: bundleID) else { throw MediaBridgeError.notAuthorized }
        let body: String
        switch command {
        case .togglePlayPause:
            // One fast `playpause` event. Music's `player state` can lag behind
            // it, so read the state before toggling and hand the requested
            // result to `nowPlaying()` instead of waiting inside this script:
            // `delay` / `repeat` in a tell block is slow and unreliable, and a
            // stale read paints the old play/pause icon on the next render.
            playStateExpectation = nil
            let requested = try run("""
            tell application id "\(bundleID)"
              set wasPlaying to (player state is playing)
              playpause
              return (not wasPlaying)
            end tell
            """)?.booleanValue
            playStateExpectation = requested.map {
                MediaPlayStateExpectation(isPlaying: $0, deadline: .now() + .milliseconds(600))
            }
            return
        case .next, .previous:
            body = command == .next ? "next track" : "previous track"
        case .like: body = "set favorited of current track to true"
        case .unlike: body = "set favorited of current track to false"
        }
        _ = try run("tell application id \"\(bundleID)\" to \(body)")
    }

    func artwork(bundleID: String) throws -> Data? {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        guard isRunning(bundleID), ensureConsent(bundleID: bundleID) else { return nil }
        guard let track = lastNowPlaying else { return nil }
        // The screen's text and cover are fetched separately. Never publish a
        // cover from a track that advanced between those two reads.
        if let cache = artworkCache, Self.sameTrack(cache.track, track) { return cache.data }
        // One script reads identity, artwork count and bytes together so the
        // result can be checked against the snapshot the screen shows. Music's
        // `current track` is a live reference: it may move between statements.
        let script = """
        tell application id "\(bundleID)"
          try
            set t to current track
            set idBefore to persistent ID of t
            set trackClass to "unknown"
            try
              set trackClass to (class of t) as text
            end try
            if trackClass is "URL track" then return {idBefore, idBefore, trackClass, 0, ""}
            set artCount to count of artworks of t
            if artCount > 0 then
              set coverData to raw data of artwork 1 of t
              set idAfter to persistent ID of current track
              return {idBefore, idAfter, trackClass, artCount, coverData}
            end if
            set idAfter to persistent ID of current track
            return {idBefore, idAfter, trackClass, artCount, ""}
          on error errText number errNum
            return {"", "", "error " & errNum, -1, ""}
          end try
        end tell
        """
        let result = try run(script)
        let probe = Self.parseArtworkProbe(result)
        let tag = "track=\(Self.shortID(track.trackID)) class=\(probe.kind) artworks=\(probe.count) "
            + "idBefore=\(Self.shortID(probe.idBefore)) idAfter=\(Self.shortID(probe.idAfter)) "
            + "bytes=\(probe.data?.count ?? 0) hash=\(probe.data.map(Self.fingerprint) ?? "-")"
        // Reject a cover whose track moved while it was being read, or that
        // belongs to a different track than the one the screen shows.
        guard probe.idBefore == track.trackID, probe.idAfter == track.trackID else {
            AppLogger.debug("Artwork discarded: track changed during read. \(tag)")
            return nil
        }
        guard let latest = lastNowPlaying, Self.sameTrack(track, latest) else {
            AppLogger.debug("Artwork discarded: snapshot advanced. \(tag)")
            return nil
        }
        // Streaming tracks are one reused `URL track` proxy whose artwork lags
        // one queue position behind: track N reports track N-1's cover, stable
        // over time (measured 0.1–8 s after a skip). Showing it would always be
        // wrong, so the screen keeps its placeholder for these tracks.
        guard Self.trustsArtwork(trackClass: probe.kind) else {
            artworkCache = (track, nil)
            AppLogger.debug("Artwork skipped: streaming track. \(tag)")
            return nil
        }
        // Music may expose the new track before its artwork is ready. Do not
        // cache nil: retry on the next normal refresh.
        guard let data = probe.data else {
            AppLogger.debug("Artwork unavailable. \(tag)")
            return nil
        }
        artworkCache = (track, data)
        AppLogger.debug("Artwork fetched. \(tag)")
        return data
    }

    private struct ArtworkProbe {
        var idBefore = "", idAfter = "", kind = "?"
        var count = -1
        var data: Data?
    }

    private static func parseArtworkProbe(_ descriptor: NSAppleEventDescriptor?) -> ArtworkProbe {
        guard let d = descriptor, d.numberOfItems == 5 else { return ArtworkProbe() }
        var probe = ArtworkProbe()
        probe.idBefore = d.atIndex(1)?.stringValue ?? ""
        probe.idAfter = d.atIndex(2)?.stringValue ?? ""
        probe.kind = d.atIndex(3)?.stringValue ?? "?"
        probe.count = Int(d.atIndex(4)?.int32Value ?? -1)
        if probe.count > 0, let raw = d.atIndex(5) {
            let bytes = raw.data
            probe.data = bytes.isEmpty ? nil : bytes
        }
        return probe
    }

    /// Music's script reports covers of streaming (`URL track`) items one
    /// queue position late; only library-backed track classes are trusted.
    static func trustsArtwork(trackClass: String) -> Bool { trackClass != "URL track" }

    private static func shortID(_ id: String) -> String { String(id.suffix(6)) }

    /// Cheap content fingerprint for logs only (FNV-1a over the first 4 KiB).
    private static func fingerprint(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data.prefix(4096) { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private static func sameTrack(_ a: NowPlaying, _ b: NowPlaying) -> Bool {
        a.trackID == b.trackID && a.title == b.title && a.artist == b.artist && a.album == b.album
    }

    private static func scriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
        let bundleID = try requireMusic()
        // Keywords come from the fixed card pool; strip anything that could
        // break out of the AppleScript string literal anyway.
        let keywords = genreKeywords
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" } }
            .filter { !$0.isEmpty }
        let list = keywords.map { "\"\($0)\"" }.joined(separator: ", ")
        // `matched` is an AppleScript terminology word in Music, so the flag
        // is named didMatch.
        let script = """
        tell application id "\(bundleID)"
          set pool to {}
          repeat with kw in {\(list)}
            try
              set pool to pool & (every track of library playlist 1 whose genre contains (kw as text))
            end try
          end repeat
          set didMatch to ((count of pool) > 0)
          if not didMatch then
            if (count of tracks of library playlist 1) is 0 then return {}
            set pool to {some track of library playlist 1}
          end if
          set t to some item of pool
          return {persistent ID of t, name of t, artist of t, bpm of t, didMatch}
        end tell
        """
        guard let result = try run(script), result.numberOfItems == 5 else { return nil }
        return PickedTrack(persistentID: result.atIndex(1)?.stringValue ?? "",
                           title: result.atIndex(2)?.stringValue ?? "",
                           artist: result.atIndex(3)?.stringValue ?? "",
                           bpm: result.atIndex(4).flatMap(Self.double) ?? 0,
                           matchedGenre: result.atIndex(5)?.booleanValue ?? false)
    }

    func play(persistentID: String) throws {
        let bundleID = try requireMusic()
        let id = persistentID.filter { $0.isLetter || $0.isNumber }
        _ = try run("tell application id \"\(bundleID)\" to play (first track of library playlist 1 whose persistent ID is \"\(id)\")")
    }

    func pausePlayback() throws {
        let bundleID = try requireMusic()
        _ = try run("tell application id \"\(bundleID)\" to pause")
    }

    func currentTrack() throws -> NowPlaying? {
        try nowPlaying(bundleID: Self.musicBundleID)
    }

    // MARK: - Private

    private func requireMusic() throws -> String {
        let bundleID = Self.musicBundleID
        guard isRunning(bundleID) else { throw MediaBridgeError.notRunning }
        guard ensureConsent(bundleID: bundleID) else { throw MediaBridgeError.notAuthorized }
        return bundleID
    }

    /// Automation consent without blocking the caller on the system prompt:
    /// when undetermined, ask once in the background and report "not yet".
    private func ensureConsent(bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            return true
        case OSStatus(errAEEventWouldRequireUserConsent):
            if !consentRequested {
                consentRequested = true
                AppLogger.info("Requesting automation consent. target=\(bundleID)")
                DispatchQueue.global(qos: .userInitiated).async {
                    let answer = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, true)
                    AppLogger.info("Automation consent answered. target=\(bundleID) status=\(answer)")
                }
            }
            return false
        default:
            AppLogger.throttledWarning(key: "media.consent.\(bundleID)",
                                       "Automation not permitted. target=\(bundleID) status=\(status)")
            return false
        }
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor? {
        dispatchPrecondition(condition: .onQueue(queue))
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { throw MediaBridgeError.scriptFailed(-1) }
            compiled[source] = created
            script = created
        }
        let started = DispatchTime.now()
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
            if code != -1728 {
                AppLogger.throttledWarning(key: "media.script.\(code)", "AppleScript failed. code=\(code) ms=\(String(format: "%.1f", ms))")
            }
            throw MediaBridgeError.scriptFailed(code)
        }
        AppLogger.verbose("AppleScript finished. ms=\(String(format: "%.1f", ms))")
        return result
    }

    private static func double(_ descriptor: NSAppleEventDescriptor) -> Double? {
        descriptor.doubleValue
    }
}
