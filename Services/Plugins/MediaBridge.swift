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
    let isPlaying: Bool
    let title: String
    let artist: String
    let album: String
    let position: Double
    let duration: Double
    let liked: Bool
    let canLike: Bool

    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }

    var jsObject: [String: Any] {
        ["playing": isPlaying, "title": title, "artist": artist, "album": album, "position": position,
         "duration": duration, "progress": progress, "liked": liked, "canLike": canLike]
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
    private var artworkCache: (trackID: String, data: Data?)?
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
          return {(player state is playing), name of t, artist of t, album of t, player position, duration of t, favorited of t}
        end tell
        """
        do {
            guard let result = try run(script), result.numberOfItems == 7 else { return nil }
            func item(_ i: Int) -> NSAppleEventDescriptor? { result.atIndex(i) }
            return NowPlaying(
                isPlaying: item(1)?.booleanValue ?? false,
                title: item(2)?.stringValue ?? "",
                artist: item(3)?.stringValue ?? "",
                album: item(4)?.stringValue ?? "",
                position: item(5).flatMap(Self.double) ?? 0,
                duration: item(6).flatMap(Self.double) ?? 0,
                liked: item(7)?.booleanValue ?? false,
                canLike: true
            )
        } catch MediaBridgeError.scriptFailed(-1728) {
            return nil  // no current track
        }
    }

    func perform(_ command: MediaCommand, bundleID: String) throws {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        guard isRunning(bundleID) else { return }
        guard ensureConsent(bundleID: bundleID) else { throw MediaBridgeError.notAuthorized }
        let body: String
        switch command {
        case .togglePlayPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .like: body = "set favorited of current track to true"
        case .unlike: body = "set favorited of current track to false"
        }
        _ = try run("tell application id \"\(bundleID)\" to \(body)")
    }

    func artwork(bundleID: String) throws -> Data? {
        guard supports(bundleID: bundleID) else { throw MediaBridgeError.unsupportedApp }
        guard isRunning(bundleID), ensureConsent(bundleID: bundleID) else { return nil }
        let trackID: String
        do {
            guard let id = try run("tell application id \"\(bundleID)\" to return persistent ID of current track")?.stringValue
            else { return nil }
            trackID = id
        } catch MediaBridgeError.scriptFailed(-1728) {
            return nil
        }
        if let cache = artworkCache, cache.trackID == trackID { return cache.data }
        let script = """
        tell application id "\(bundleID)"
          try
            return raw data of artwork 1 of current track
          on error
            return missing value
          end try
        end tell
        """
        let descriptor = try run(script)
        let data = descriptor.flatMap { $0.descriptorType == typeType ? nil : $0.data }.flatMap { $0.isEmpty ? nil : $0 }
        artworkCache = (trackID, data)
        AppLogger.debug("Artwork fetched. hasArtwork=\(data != nil) bytes=\(data?.count ?? 0)")
        return data
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
