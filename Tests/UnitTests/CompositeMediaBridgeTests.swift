import AppKit
import XCTest
@testable import Switchly

final class CompositeMediaBridgeTests: XCTestCase {
    private let process = MediaRemoteProcessIdentity(pid: 42, launchDate: Date(timeIntervalSince1970: 100))

    func testRemotePairingRetainsLikeAndDirectedControlsAndLibrary() throws {
        let fixture = makeFixture()
        defer { fixture.interest.cancel() }
        fixture.child.waitForLaunch()
        fixture.child.send(payload())
        try fixture.bridge.queue.sync {
            let read = try fixture.bridge.readContext(bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(read.nowPlaying?.title, "Song")
            XCTAssertEqual(read.nowPlaying?.position ?? -1, 25, accuracy: 1)
            XCTAssertEqual(read.nowPlaying?.liked, true)
            XCTAssertEqual(read.nowPlaying?.canLike, true)
            XCTAssertTrue(read.isCurrent())
            try fixture.bridge.perform(.like, bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(fixture.script.commands, [.like])
            XCTAssertFalse(read.isCurrent())
            XCTAssertEqual(try fixture.bridge.pickRandomTrack(genreKeywords: ["Rock"])?.persistentID, "picked")
            try fixture.bridge.play(persistentID: "picked")
            try fixture.bridge.pausePlayback()
            XCTAssertEqual(fixture.script.played, "picked")
            XCTAssertEqual(fixture.script.pauses, 1)
            XCTAssertEqual(try fixture.bridge.currentTrack()?.trackID, "music-id")
        }
    }

    func testBrowserTakeoverAndPauseRemainWholeScriptFallback() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        f.child.send(payload())
        let read = try f.bridge.queue.sync { try f.bridge.readContext(bundleID: MediaRemoteState.bundleID) }
        f.child.send(payload(bundle: "com.google.Chrome", playing: false))
        try f.bridge.queue.sync {
            XCTAssertFalse(read.isCurrent())
            let fallback = try f.bridge.readContext(bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(fallback.nowPlaying?.position, 2)
            XCTAssertEqual(fallback.nowPlaying?.liked, true)
            XCTAssertNil(fallback.artwork)
            XCTAssertTrue(fallback.isCurrent())
        }
    }

    func testPermissionAbsenceCannotExposeRemoteOrLoseScriptError() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        f.child.send(payload())
        f.script.track = nil
        try f.bridge.queue.sync {
            XCTAssertNil(try f.bridge.readContext(bundleID: MediaRemoteState.bundleID).nowPlaying)
            f.script.error = MediaBridgeError.notAuthorized
            XCTAssertThrowsError(try f.bridge.perform(.togglePlayPause, bundleID: MediaRemoteState.bundleID)) {
                XCTAssertEqual($0 as? MediaBridgeError, .notAuthorized)
            }
        }
    }

    func testMetadataMismatchAndChangeDuringPairingRejectRemote() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        f.child.send(payload(title: "Other"))
        try f.bridge.queue.sync {
            XCTAssertEqual(try f.bridge.readContext(bundleID: MediaRemoteState.bundleID).nowPlaying?.position, 2)
        }
        f.child.send(payload())
        var reads = 0
        f.script.onRead = {
            reads += 1
            if reads == 2 { f.script.track?.trackID = "new-id" }
        }
        try f.bridge.queue.sync {
            XCTAssertEqual(try f.bridge.readContext(bundleID: MediaRemoteState.bundleID).nowPlaying?.position, 2)
        }
    }

    func testNoCandidateFallbackUsesTwoSamplesAndStillValidatesBeforePublication() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        try f.bridge.queue.sync {
            let read = try f.bridge.readContext(bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(read.source, .appleScript)
            XCTAssertEqual(f.script.reads, 2)
            XCTAssertTrue(read.isCurrent())
            XCTAssertEqual(f.script.reads, 3)
            f.script.track?.trackID = "new-id"
            XCTAssertFalse(read.isCurrent())
        }
    }

    func testMismatchedCandidateReusesLastSampleForFallback() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        f.child.send(payload(title: "Other"))
        try f.bridge.queue.sync {
            let read = try f.bridge.readContext(bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(read.source, .appleScript)
            XCTAssertEqual(f.script.reads, 3)
            XCTAssertTrue(read.isCurrent())
            XCTAssertEqual(f.script.reads, 4)
        }
    }

    func testReusedFallbackSampleStillRejectsArtworkWhenTrackChangesDuringRead() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        let image = Self.bitmap().tiffRepresentation
        f.script.artworkData = image
        f.script.onArtwork = { f.script.track?.trackID = "new-id" }
        try f.bridge.queue.sync {
            let read = try f.bridge.readContext(bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(read.nowPlaying?.trackID, "new-id")
            XCTAssertNil(read.artwork)
            XCTAssertNil(read.artworkToken)
            XCTAssertEqual(f.script.reads, 2)
            XCTAssertTrue(read.isCurrent())
        }
    }

    func testPairedCandidateRetainsFinalPlaybackAndLikeValidation() throws {
        let f = makeFixture()
        defer { f.interest.cancel() }
        f.child.waitForLaunch()
        f.child.send(payload())
        try f.bridge.queue.sync {
            let read = try f.bridge.readContext(bundleID: MediaRemoteState.bundleID)
            XCTAssertEqual(read.source, .mediaRemote)
            XCTAssertEqual(f.script.reads, 2)
            XCTAssertTrue(read.isCurrent())
            XCTAssertEqual(f.script.reads, 3)
            f.script.track = f.script.track?.withPlaying(false)
            XCTAssertFalse(read.isCurrent())
        }
    }

    func testSharedInterestStopsOnlyAfterLastRelease() {
        let child = MRBridgeChild()
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process }, observeWorkspace: false)
        let first = session.acquire {}
        let second = session.acquire {}
        child.waitForLaunch()
        XCTAssertEqual(child.launchCount, 1)
        first.cancel()
        first.cancel()
        let barrier = expectation(description: "still delivering")
        child.send(payload())
        XCTAssertNotNil(session.snapshot().0)
        XCTAssertEqual(child.terminateCount, 0)
        second.cancel()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(1)
            while child.terminateCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            barrier.fulfill()
        }
        wait(for: [barrier], timeout: 2)
        XCTAssertEqual(child.terminateCount, 1)
        XCTAssertNil(session.snapshot().0)
    }

    func testSleepWakeRebuildsAndRejectsOldConnection() {
        let children = [MRBridgeChild(), MRBridgeChild()]
        var index = 0
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: {
            defer { index += 1 }; return children[min(index, 1)]
        }), identity: { self.process }, observeWorkspace: false)
        let interest = session.acquire {}
        defer { interest.cancel() }
        children[0].waitForLaunch()
        children[0].send(payload())
        XCTAssertNotNil(session.snapshot().0)
        session.setSleeping(true)
        session.setSleeping(false)
        children[1].waitForLaunch()
        XCTAssertNil(session.snapshot().0)
        children[0].send(payload(title: "Late"))
        XCTAssertNil(session.snapshot().0)
        children[1].send(payload(title: "New"))
        XCTAssertEqual(session.snapshot().0?.nowPlaying.title, "New")
    }

    func testLateImageDecodeCannotRestoreCoverAfterSourceTakeover() async throws {
        let child = MRBridgeChild()
        let began = expectation(description: "decode began")
        let gate = DispatchSemaphore(value: 0)
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process },
                                        observeWorkspace: false, decodeArtwork: { _ in
            began.fulfill()
            _ = gate.wait(timeout: .now() + 2)
            return NSImage(size: NSSize(width: 2, height: 2))
        })
        let interest = session.acquire {}
        defer { interest.cancel(); gate.signal() }
        child.waitForLaunch()
        let event = payload().replacingOccurrences(of: "\"elapsedTime\":25", with: "\"artworkData\":\"AQID\",\"elapsedTime\":25")
        child.send(event)
        await fulfillment(of: [began], timeout: 1)
        child.send(payload(bundle: "com.google.Chrome"))
        gate.signal()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(session.snapshot().0)
        XCTAssertNil(session.snapshot().1)
    }

    func testFailedCycleDoesNotRestartForAnotherConsumer() {
        let child = MRBridgeChild()
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process }, observeWorkspace: false)
        let first = session.acquire {}
        child.waitForLaunch()
        child.send("invalid")
        let second = session.acquire {}
        // 该 acquire 在生命周期串行队列处理；睡眠/唤醒才开启另一个周期。
        let settled = expectation(description: "interest settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(child.launchCount, 1)
        XCTAssertNil(session.snapshot().0)
        first.cancel()
        second.cancel()
    }

    func testCachedDisplayChecksDoNotConsultProcessProvider() {
        var identityCalls = 0
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { MRBridgeChild() }), identity: {
            identityCalls += 1
            return self.process
        }, observeWorkspace: false)
        _ = session.snapshot()
        _ = session.isCurrent(0)
        _ = session.isArtworkCurrent(nil)
        XCTAssertEqual(identityCalls, 0)
    }

    func testRecentCoverReturnsWithoutAnotherDecodeAndExplicitClearRevokesIt() async throws {
        let child = MRBridgeChild()
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process },
                                        observeWorkspace: false, decodeArtwork: { _ in Self.bitmap() })
        let interest = session.acquire {}
        defer { interest.cancel() }
        child.waitForLaunch()
        child.send(payloadWithCover())
        let first = try await waitForImage(session)
        session.willChangeTrack()
        XCTAssertNil(session.snapshot().1)
        child.send(payload(title: "B"))
        XCTAssertNil(session.snapshot().1)
        child.send(payload())
        XCTAssertTrue(session.snapshot().1 === first)
        XCTAssertNotNil(session.snapshot().0?.artworkToken)
        child.send(payload(title: "B"))
        child.send(payloadWithCover())
        XCTAssertTrue(session.snapshot().1 === first)
        child.send("{\"type\":\"data\",\"diff\":true,\"payload\":{\"artworkData\":null}}")
        XCTAssertNil(session.snapshot().1)
        child.send(payload(title: "B"))
        child.send(payload())
        XCTAssertNil(session.snapshot().1)
    }

    func testBrowserTakeoverClearsHistoryAndMetadataCannotAliasCachedCover() async throws {
        let child = MRBridgeChild()
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process },
                                        observeWorkspace: false, decodeArtwork: { _ in Self.bitmap() })
        let interest = session.acquire {}
        defer { interest.cancel() }
        child.waitForLaunch()
        child.send(payloadWithCover())
        _ = try await waitForImage(session)
        child.send(payload(title: "Changed metadata"))
        XCTAssertNil(session.snapshot().1)
        child.send(payload())
        XCTAssertNotNil(session.snapshot().1)
        child.send(payload(bundle: "com.apple.Safari"))
        XCTAssertNil(session.snapshot().1)
        child.send(payload())
        XCTAssertNil(session.snapshot().1)
    }

    func testReplacementDecodeFailureCannotResurrectHistory() async throws {
        let child = MRBridgeChild()
        let failed = expectation(description: "replacement decoded")
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process },
                                        observeWorkspace: false, decodeArtwork: { data in
            if data == Data([1, 2, 3]) { return Self.bitmap() }
            failed.fulfill()
            return nil
        })
        let interest = session.acquire {}
        defer { interest.cancel() }
        child.waitForLaunch()
        child.send(payloadWithCover())
        _ = try await waitForImage(session)
        child.send(payloadWithCover().replacingOccurrences(of: "AQID", with: "BA=="))
        XCTAssertNil(session.snapshot().1)
        await fulfillment(of: [failed], timeout: 1)
        child.send(payload(title: "B"))
        child.send(payload())
        XCTAssertNil(session.snapshot().1)
    }

    func testHistoryLRUEvictionAndBitmapBudget() {
        func key(_ id: String, duration: Double = 100) -> MediaArtworkHistory.Key {
            MediaArtworkHistory.Key(identity: [id], duration: duration)
        }
        var history = MediaArtworkHistory()
        let image = Self.bitmap()
        for index in 0..<8 { history.insert(image, digest: "cover", key: key(String(index))) }
        XCTAssertNotNil(history.take(key("0", duration: 100.073)))
        XCTAssertNil(history.take(key("0", duration: 102)))
        history.insert(image, digest: "new", key: key("8"))
        XCTAssertNil(history.take(key("1")))
        XCTAssertNotNil(history.take(key("0")))
        XCTAssertEqual(history.entries.count, 8)
        XCTAssertLessThanOrEqual(history.bytes, MediaArtworkHistory.maxBytes)
        history.insert(NSImage(size: NSSize(width: 2, height: 2)), digest: "unsupported", key: key("0"))
        XCTAssertNil(history.take(key("0")))
        let large = Self.bitmap(edge: 1024)
        history.insert(large, digest: "large", key: key("large"))
        XCTAssertNil(history.take(key("large")))
    }

    private static func bitmap(edge: Int = 2) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: edge * 4, bitsPerPixel: 32)!
        let image = NSImage(size: NSSize(width: edge, height: edge))
        image.addRepresentation(rep)
        return image
    }

    private func payloadWithCover() -> String {
        payload().replacingOccurrences(of: "\"elapsedTime\":25", with: "\"artworkData\":\"AQID\",\"elapsedTime\":25")
    }

    private func waitForImage(_ session: MediaRemoteSession) async throws -> NSImage {
        for _ in 0..<200 {
            if let image = session.snapshot().1 { return image }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try XCTUnwrap(session.snapshot().1)
    }

    private func makeFixture() -> (bridge: CompositeMediaBridge, script: MRScript, child: MRBridgeChild, interest: MediaReadInterest) {
        let child = MRBridgeChild()
        let session = MediaRemoteSession(stream: MediaRemoteStream(makeChild: { child }), identity: { self.process }, observeWorkspace: false)
        let script = MRScript()
        let bridge = CompositeMediaBridge(script: script, session: session, identity: { self.process })
        return (bridge, script, child, bridge.acquireReadInterest {})
    }

    private func payload(bundle: String = "com.apple.Music", title: String = "Song", playing: Bool = true) -> String {
        """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"\(bundle)","processIdentifier":42,"title":"\(title)","artist":"Artist","album":"Album","uniqueIdentifier":"remote-id","duration":100,"elapsedTime":25,"playing":\(playing)}}
        """
    }
}

private final class MRScript: MediaBridging, MusicLibraryPlaying, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.composite.script")
    var track: NowPlaying? = {
        var value = NowPlaying(isPlaying: true, title: "Song", artist: "Artist", album: "Album", position: 2,
                               duration: 100, liked: true, canLike: true)
        value.trackID = "music-id"
        return value
    }()
    var error: Error?
    var commands: [MediaCommand] = []
    var played: String?
    var pauses = 0
    var onRead: (() -> Void)?
    var reads = 0
    var artworkData: Data?
    var onArtwork: (() -> Void)?
    func supports(bundleID: String) -> Bool { bundleID == MediaRemoteState.bundleID }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { reads += 1; onRead?(); return track }
    func artwork(bundleID: String) throws -> Data? { onArtwork?(); return artworkData }
    func perform(_ command: MediaCommand, bundleID: String) throws { if let error { throw error }; commands.append(command) }
    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
        PickedTrack(persistentID: "picked", title: "Picked", artist: "Artist", bpm: 120, matchedGenre: true)
    }
    func play(persistentID: String) throws { played = persistentID }
    func pausePlayback() throws { pauses += 1 }
    func currentTrack() throws -> NowPlaying? { track }
}

private final class MRBridgeChild: MediaRemoteChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((MediaRemoteProcessOutput) -> Void)?
    private var launches = 0
    private var terminations = 0
    private var running = false
    var launchCount: Int { lock.lock(); defer { lock.unlock() }; return launches }
    var terminateCount: Int { lock.lock(); defer { lock.unlock() }; return terminations }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func launch(output: @escaping (MediaRemoteProcessOutput) -> Void) throws {
        lock.lock(); callback = output; running = true; launches += 1; lock.unlock()
    }
    func terminate() { lock.lock(); running = false; terminations += 1; lock.unlock() }
    func kill() { terminate() }
    func send(_ json: String) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(.stdout(Data((json + "\n").utf8)))
    }
    func waitForLaunch() {
        let deadline = Date().addingTimeInterval(2)
        while launchCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertGreaterThan(launchCount, 0)
    }
}
