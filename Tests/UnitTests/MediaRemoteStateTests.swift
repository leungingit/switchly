import XCTest
@testable import Switchly

final class MediaRemoteStateTests: XCTestCase {
    private let identity = MediaRemoteProcessIdentity(pid: 42, launchDate: Date(timeIntervalSince1970: 1))
    private let wall = Date(timeIntervalSince1970: 100)

    private func event(_ fields: [String: Any] = [:], diff: Bool = false) throws -> MediaRemoteEvent {
        try .decode(JSONSerialization.data(withJSONObject: ["type": "data", "diff": diff, "payload": fields]))
    }

    private func music(_ overrides: [String: Any] = [:]) throws -> MediaRemoteEvent {
        var fields: [String: Any] = ["bundleIdentifier": "com.apple.Music", "processIdentifier": 42,
            "title": "Song", "artist": "Artist", "album": "Album", "uniqueIdentifier": 7,
            "contentItemIdentifier": "queue:1", "playing": true, "duration": 180,
            "elapsedTime": 10, "playbackRate": 1, "timestamp": "1970-01-01T00:01:40Z",
            "artworkData": Data([1, 2, 3]).base64EncodedString(), "artworkMimeType": "image/jpeg"]
        fields.merge(overrides) { _, new in new }
        return try event(fields)
    }

    private func apply(_ event: MediaRemoteEvent, to state: inout MediaRemoteState,
                       uptime: TimeInterval = 10, connection: UUID? = nil) throws {
        try state.apply(event, connection: connection ?? state.connection, wallTime: wall, uptime: uptime)
    }

    func testSnapshotProjectionKeepsPlaybackRateAndTrackIdentity() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(["playbackRate": 2]), to: &state)
        let initial = try XCTUnwrap(state.snapshot)
        let later = try XCTUnwrap(state.snapshot(at: 12))
        XCTAssertEqual(later.nowPlaying.position, 14, accuracy: 0.001)
        XCTAssertEqual(later.playbackRate, 2)
        XCTAssertEqual(initial.token, later.token)
    }

    func testBrowserTakeoverAndPausedBrowserNeverProduceMusicSnapshot() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        XCTAssertNotNil(state.snapshot?.artwork)
        try apply(event(["bundleIdentifier": "com.citrolabs.ego.lite", "processIdentifier": 99,
                         "title": "Browser", "playing": true]), to: &state)
        XCTAssertEqual(state.selection, .sourceMismatch)
        XCTAssertNil(state.snapshot)
        try apply(event(["playing": false], diff: true), to: &state)
        XCTAssertEqual(state.selection, .sourceMismatch)
        XCTAssertNil(state.snapshot)
        try apply(music(["artworkData": NSNull()]), to: &state)
        XCTAssertEqual(state.selection, .ready)
        XCTAssertNil(state.snapshot?.artwork)
    }

    func testParentApplicationCannotImpersonateMusic() throws {
        var state = MediaRemoteState(target: identity)
        try apply(event(["bundleIdentifier": "browser", "parentApplicationBundleIdentifier": "com.apple.Music",
                         "processIdentifier": 42, "title": "Browser", "playing": true]), to: &state)
        XCTAssertEqual(state.selection, .sourceMismatch)
    }

    func testWrongOrMissingPIDRejectsArtwork() throws {
        for pid: Any in [43, 42.5, NSNull()] {
            var state = MediaRemoteState(target: identity)
            try apply(music(["processIdentifier": pid]), to: &state)
            XCTAssertEqual(state.selection, .invalidIdentity)
            XCTAssertNil(state.snapshot)
        }
    }

    func testNoTargetAndEmptyFullSnapshotAreDistinct() throws {
        var state = MediaRemoteState()
        try apply(music(), to: &state)
        XCTAssertEqual(state.selection, .noTarget)
        state.updateTarget(identity)
        try apply(event(), to: &state)
        XCTAssertEqual(state.selection, .noSession)
    }

    func testMissingTitleOrPlayingRejectsSnapshot() throws {
        for overrides: [String: Any] in [["title": ""], ["playing": NSNull()]] {
            var state = MediaRemoteState(target: identity)
            try apply(music(overrides), to: &state)
            XCTAssertEqual(state.selection, .invalidMetadata)
        }
    }

    func testDiffCannotStartAConnectionAndOldConnectionIsIgnored() throws {
        var state = MediaRemoteState(target: identity)
        XCTAssertThrowsError(try apply(event(["title": "late"], diff: true), to: &state))
        let old = state.connection
        state.begin(connection: UUID(), target: identity)
        try apply(music(), to: &state, connection: old)
        XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.selection, .awaitingFullSnapshot)
    }

    func testNullDeletesButAbsentFieldsRemainAndFullReplaces() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let cover = state.snapshot?.artworkToken
        try apply(event(["elapsedTime": 12], diff: true), to: &state)
        XCTAssertEqual(state.snapshot?.artworkToken, cover)
        try apply(event(["artworkData": NSNull()], diff: true), to: &state)
        XCTAssertNil(state.snapshot?.artwork)
        try apply(music(), to: &state)
        try apply(music(["artworkData": NSNull()]), to: &state)
        XCTAssertNil(state.snapshot?.artwork)
        try apply(event(), to: &state)
        XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.selection, .noSession)
    }

    func testNewTrackClearsInheritedCoverAndLateDecodeToken() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let old = try XCTUnwrap(state.snapshot?.token)
        try apply(event(["title": "Next", "uniqueIdentifier": 8], diff: true), to: &state)
        XCTAssertNil(state.snapshot?.artwork)
        XCTAssertFalse(state.isCurrent(old))
        try apply(event(["artworkData": Data([4]).base64EncodedString()], diff: true), to: &state)
        XCTAssertEqual(state.snapshot?.nowPlaying.title, "Next")
        XCTAssertEqual(state.snapshot?.artwork, Data([4]))
    }

    func testFullSnapshotWithoutArtworkDoesNotReusePreviousImage() throws {
        var state = MediaRemoteState(target: identity)
        let full = try music()
        try apply(full, to: &state)
        let fields = full.fields.filter { $0.key != .artworkData && $0.key != .artworkMimeType }
        try apply(MediaRemoteEvent(isDiff: false, fields: fields), to: &state)
        XCTAssertNil(state.snapshot?.artwork)
    }

    func testReusedNativeIdentifierWithChangedMetadataIsNewTrack() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let first = try XCTUnwrap(state.snapshot?.token.track)
        try apply(event(["title": "Different song"], diff: true), to: &state)
        XCTAssertGreaterThan(try XCTUnwrap(state.snapshot?.token.track), first)
        XCTAssertNil(state.snapshot?.artwork)
    }

    func testControlRequestRevokesCoverBeforeTrackChangeIsConfirmed() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        state.willChangeTrack()
        try apply(event(["artworkData": Data([9]).base64EncodedString()], diff: true), to: &state)
        XCTAssertEqual(state.selection, .awaitingTrackChange)
        XCTAssertNil(state.snapshot)
        try apply(event(["uniqueIdentifier": 8, "title": "Next"], diff: true), to: &state)
        XCTAssertEqual(state.selection, .ready)
        XCTAssertNil(state.snapshot?.artwork)
    }

    func testPreviousRestartRequiresExplicitRewindAndRebuildsProgress() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let old = try XCTUnwrap(state.snapshot?.token)
        state.willChangeTrack(allowRestart: true)
        try apply(event(["artworkData": "BA=="], diff: true), to: &state)
        XCTAssertNil(state.snapshot)
        try apply(event(["elapsedTime": 11], diff: true), to: &state)
        XCTAssertNil(state.snapshot)
        try apply(event(["elapsedTime": 0], diff: true), to: &state)
        XCTAssertEqual(state.selection, .ready)
        XCTAssertEqual(state.snapshot?.nowPlaying.position, 0)
        XCTAssertNil(state.snapshot?.artwork)
        XCTAssertNotEqual(state.snapshot?.token.track, old.track)
        XCTAssertEqual(state.snapshot(at: 12)?.nowPlaying.position, 2)
    }

    func testNextOrPreviousNearStartCannotUseSameTrackRewind() throws {
        for (allowRestart, position) in [(false, 10), (true, 1)] {
            var state = MediaRemoteState(target: identity)
            try apply(music(["elapsedTime": position]), to: &state)
            state.willChangeTrack(allowRestart: allowRestart)
            try apply(event(["elapsedTime": 0], diff: true), to: &state)
            XCTAssertNil(state.snapshot)
            XCTAssertEqual(state.selection, .awaitingTrackChange)
        }
    }

    func testArtworkBudgetRejectsOversizedPayloadWithoutLosingMetadata() throws {
        var state = MediaRemoteState(target: identity)
        let bytes = Data(repeating: 1, count: MediaRemoteBudget.artworkBytes + 1)
        try apply(music(["artworkData": bytes.base64EncodedString()]), to: &state)
        XCTAssertNil(state.snapshot?.artwork)
        XCTAssertTrue(state.rejectedArtwork)
        XCTAssertEqual(state.snapshot?.nowPlaying.title, "Song")
    }

    func testSameMetadataDifferentNativeIDIsAmbiguous() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        try apply(event(["uniqueIdentifier": 8], diff: true), to: &state)
        XCTAssertTrue(try XCTUnwrap(state.snapshot).isAmbiguous)
        XCTAssertNil(state.snapshot?.artwork)
    }

    func testPIDReuseAndInvalidationRevokeEverything() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let old = try XCTUnwrap(state.snapshot?.token)
        state.updateTarget(MediaRemoteProcessIdentity(pid: 42, launchDate: Date(timeIntervalSince1970: 2)))
        XCTAssertNil(state.snapshot)
        XCTAssertFalse(state.isCurrent(old))
        try apply(music(), to: &state, connection: old.connection)
        XCTAssertNil(state.snapshot)
        try apply(music(), to: &state)
        state.invalidate()
        XCTAssertNil(state.snapshot)
    }

    func testPauseResumeAndArtworkOnlyUpdateDoNotChangeTrackGeneration() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let track = state.snapshot?.token.track
        try apply(event(["playing": false], diff: true), to: &state, uptime: 15)
        XCTAssertEqual(state.snapshot?.nowPlaying.position, 15)
        try apply(event(["playbackRate": 0], diff: true), to: &state, uptime: 16)
        XCTAssertEqual(state.snapshot?.nowPlaying.position, 15)
        let token = state.snapshot?.artworkToken
        try apply(event(["composer": "ignored future field"], diff: true), to: &state, uptime: 40)
        XCTAssertEqual(state.snapshot?.nowPlaying.position, 15)
        try apply(event(["playing": true], diff: true), to: &state, uptime: 45)
        try apply(event(["playbackRate": 1], diff: true), to: &state, uptime: 45)
        try apply(event(["artworkMimeType": "image/jpeg"], diff: true), to: &state, uptime: 50)
        XCTAssertEqual(state.snapshot?.nowPlaying.position, 20)
        XCTAssertEqual(state.snapshot?.token.track, track)
        XCTAssertEqual(state.snapshot?.artworkToken, token)
    }

    func testSeekReanchorsAndPositionIsClamped() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        try apply(event(["elapsedTime": 170, "timestamp": "1970-01-01T00:01:40Z"], diff: true), to: &state)
        try apply(event([:], diff: true), to: &state, uptime: 30)
        XCTAssertEqual(state.snapshot?.nowPlaying.position, 180)
    }

    func testMalformedBase64DoesNotDestroyTrackMetadata() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(["artworkData": "not base64"]), to: &state)
        XCTAssertEqual(state.selection, .ready)
        XCTAssertNil(state.snapshot?.artwork)
        XCTAssertTrue(state.rejectedArtwork)
    }

    func testPairingChecksBothSamplesProcessAndCurrentToken() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        let snapshot = try XCTUnwrap(state.snapshot)
        var np = snapshot.nowPlaying
        np.trackID = "MUSIC-PERSISTENT-ID"
        let sample = MusicMediaSample(process: identity, nowPlaying: np)
        XCTAssertTrue(MediaRemotePairing.matches(snapshot, before: sample, after: sample, currentToken: snapshot.token))
        XCTAssertFalse(MediaRemotePairing.matches(snapshot, before: sample, after: sample,
                                                  currentToken: snapshot.token, knownAmbiguous: true))
        np.trackID = "NEW-MUSIC-ID"
        XCTAssertFalse(MediaRemotePairing.matches(snapshot, before: sample,
            after: MusicMediaSample(process: identity, nowPlaying: np), currentToken: snapshot.token))
        let other = MusicMediaSample(process: MediaRemoteProcessIdentity(pid: 42, launchDate: Date()), nowPlaying: np)
        XCTAssertFalse(MediaRemotePairing.matches(snapshot, before: other, after: other, currentToken: snapshot.token))
        try apply(event(["uniqueIdentifier": 8], diff: true), to: &state)
        XCTAssertFalse(MediaRemotePairing.matches(snapshot, before: sample, after: sample,
                                                  currentToken: try XCTUnwrap(state.snapshot?.token)))
    }

    func testPairingRejectsIncompleteMetadataDurationMismatchAndMissingNativeID() throws {
        var state = MediaRemoteState(target: identity)
        try apply(music(), to: &state)
        var np = try XCTUnwrap(state.snapshot).nowPlaying
        np.trackID = "MUSIC-ID"
        let sample = MusicMediaSample(process: identity, nowPlaying: np)
        let cases: [[String: Any]] = [["album": NSNull()], ["artist": "Other artist"],
            ["duration": 182], ["uniqueIdentifier": NSNull(), "contentItemIdentifier": NSNull()]]
        for overrides in cases {
            state.begin(connection: UUID(), target: identity)
            try apply(music(overrides), to: &state)
            let snapshot = try XCTUnwrap(state.snapshot)
            XCTAssertFalse(MediaRemotePairing.matches(snapshot, before: sample, after: sample,
                                                      currentToken: snapshot.token))
        }
    }
}
