import XCTest
@testable import Switchly

private final class FakeSettings: SettingsServiceProtocol {
    var settings = AppSettings.default
    func loadSettings() -> AppSettings { settings }
    func saveSettings(_ settings: AppSettings) throws { self.settings = settings }
    func observeChanges(_ handler: @escaping (AppSettings) -> Void) {}
}

private final class FakePlayer: MusicLibraryPlaying, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.gacha.player")
    var pick: Result<PickedTrack?, Error> = .success(FakePlayer.track)
    var playError: Error?
    var current: NowPlaying? = FakePlayer.nowPlaying(position: 5, playing: true)
    private(set) var keywords: [[String]] = []
    private(set) var played: [String] = []
    private(set) var pauses = 0

    static let track = PickedTrack(persistentID: "ABC123", title: "T", artist: "A", bpm: 120, matchedGenre: true)
    static func nowPlaying(position: Double, playing: Bool, title: String = "T") -> NowPlaying {
        NowPlaying(isPlaying: playing, title: title, artist: "A", album: "", position: position, duration: 200, liked: false, canLike: true)
    }

    func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
        keywords.append(genreKeywords)
        return try pick.get()
    }
    func play(persistentID: String) throws {
        if let playError { throw playError }
        played.append(persistentID)
    }
    func pausePlayback() throws { pauses += 1 }
    func currentTrack() throws -> NowPlaying? { current }
}

@MainActor
final class GachaViewModelTests: XCTestCase {
    private func make(_ player: FakePlayer) -> GachaViewModel {
        GachaViewModel(settingsService: FakeSettings(), player: player, timing: .instant)
    }

    private func wait(_ model: GachaViewModel, until: (GachaPhase) -> Bool) async {
        for _ in 0..<200 where !until(model.phase) { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testRoundReachesChoosingWithThreeCards() async {
        let model = make(FakePlayer())
        model.startRound()
        await wait(model) { $0 == .choosing }
        XCTAssertEqual(model.phase, .choosing)
        XCTAssertEqual(model.cards.count, 3)
    }

    func testStartIfIdleDoesNotRestartARoundInProgress() async {
        let model = make(FakePlayer())
        model.startRound()
        await wait(model) { $0 == .choosing }
        let cards = model.cards
        model.startIfIdle()
        XCTAssertEqual(model.cards, cards)
        XCTAssertEqual(model.phase, .choosing)
    }

    func testChoosingPicksSongFromChosenCardKeywordsAndRevealsIt() async {
        let player = FakePlayer()
        let model = make(player)
        model.startRound()
        await wait(model) { $0 == .choosing }
        let card = model.cards[1]
        model.choose(card)
        await wait(model) { $0 == .revealed(card.id) }
        XCTAssertEqual(model.phase, .revealed(card.id))
        XCTAssertEqual(model.track, FakePlayer.track)
        XCTAssertEqual(player.keywords, [card.genreKeywords])
        XCTAssertTrue(player.played.isEmpty, "revealing must not start playback")
    }

    func testPlayStartsChosenTrackThenFinishesNearEndAndPauses() async {
        let player = FakePlayer()
        let model = make(player)
        model.startRound()
        await wait(model) { $0 == .choosing }
        let card = model.cards[0]
        model.choose(card)
        await wait(model) { $0 == .revealed(card.id) }
        model.play()
        await wait(model) { $0 == .playing(card.id) }
        XCTAssertEqual(player.played, ["ABC123"])
        player.current = FakePlayer.nowPlaying(position: 199.5, playing: true)
        await wait(model) { $0 == .finished(card.id) }
        XCTAssertEqual(model.phase, .finished(card.id))
        XCTAssertEqual(player.pauses, 1)
        XCTAssertFalse(model.isAudible)
    }

    func testFinishesWhenMusicMovesToAnotherTrack() async {
        let player = FakePlayer()
        let model = make(player)
        model.startRound()
        await wait(model) { $0 == .choosing }
        let card = model.cards[0]
        model.choose(card)
        await wait(model) { $0 == .revealed(card.id) }
        model.play()
        await wait(model) { $0 == .playing(card.id) }
        player.current = FakePlayer.nowPlaying(position: 1, playing: true, title: "Other")
        await wait(model) { $0 == .finished(card.id) }
        XCTAssertEqual(player.pauses, 1)
    }

    func testAgainWhilePlayingPausesAndStartsNextRound() async {
        let player = FakePlayer()
        let model = make(player)
        model.startRound()
        await wait(model) { $0 == .choosing }
        let card = model.cards[0]
        model.choose(card)
        await wait(model) { $0 == .revealed(card.id) }
        model.play()
        await wait(model) { $0 == .playing(card.id) }
        model.startRound()
        await wait(model) { $0 == .choosing }
        XCTAssertEqual(model.phase, .choosing)
        XCTAssertNil(model.track)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(player.pauses, 1)
    }

    func testErrorsMapToFailures() async {
        let cases: [(Result<PickedTrack?, Error>, GachaFailure)] = [
            (.success(nil), .libraryEmpty),
            (.failure(MediaBridgeError.notAuthorized), .needsAuthorization),
            (.failure(MediaBridgeError.notRunning), .musicNotRunning),
            (.failure(MediaBridgeError.scriptFailed(-10003)), .failed),
        ]
        for (result, expected) in cases {
            let player = FakePlayer()
            player.pick = result
            let model = make(player)
            model.startRound()
            await wait(model) { $0 == .choosing }
            model.choose(model.cards[0])
            await wait(model) { if case .failed = $0 { return true } else { return false } }
            XCTAssertEqual(model.phase, .failed(expected))
        }
    }

    func testPlayFailureShowsFailed() async {
        let player = FakePlayer()
        player.playError = MediaBridgeError.scriptFailed(-1728)
        let model = make(player)
        model.startRound()
        await wait(model) { $0 == .choosing }
        let card = model.cards[0]
        model.choose(card)
        await wait(model) { $0 == .revealed(card.id) }
        model.play()
        await wait(model) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(model.phase, .failed(.failed))
    }
}
