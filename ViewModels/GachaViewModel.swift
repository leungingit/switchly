//
//  GachaViewModel.swift
//  Switchly
//
//  State machine of the weather gacha card in the Music Dock preview:
//  countdown → choose one of three cards → the others shatter and the chosen
//  card's song is revealed → play → finished. "Again" restarts from any phase.
//

import Combine
import Foundation

enum GachaFailure: Equatable {
    case libraryEmpty
    case needsAuthorization
    case musicNotRunning
    case failed
}

enum GachaPhase: Equatable {
    case idle
    /// 3, 2, 1 before the cards are dealt.
    case countdown(Int)
    case choosing
    /// A card was chosen; the others shatter while the song is picked.
    case picking(String)
    /// The song is shown with the play button.
    case revealed(String)
    case playing(String)
    case finished(String)
    case failed(GachaFailure)

    var chosenID: String? {
        switch self {
        case .picking(let id), .revealed(let id), .playing(let id), .finished(let id): return id
        default: return nil
        }
    }
}

struct GachaTiming {
    var countdownStep: TimeInterval = 0.9
    /// Held on the last count so the staff note can bow before the cards appear.
    var countdownBow: TimeInterval = 0.6
    var shatter: TimeInterval = 0.9
    var pollInterval: TimeInterval = 0.5
    /// Polls that may report "nothing playing" right after `play` is sent.
    var startGracePolls = 4

    static let instant = GachaTiming(countdownStep: 0, countdownBow: 0, shatter: 0, pollInterval: 0.01, startGracePolls: 2)
}

@MainActor
final class GachaViewModel: ObservableObject {
    @Published private(set) var preferences: GachaPreferences
    @Published private(set) var cards: [GachaCard] = []
    @Published private(set) var phase: GachaPhase = .idle
    @Published private(set) var track: PickedTrack?
    /// False while Music is paused, so the beat bars hold still.
    @Published private(set) var isAudible = false
    private var pity = 0
    private var flowTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private let engine: GachaEngine
    private let settingsService: SettingsServiceProtocol
    private let player: MusicLibraryPlaying
    let timing: GachaTiming
    private var rng = SystemRandomNumberGenerator()

    init(settingsService: SettingsServiceProtocol = SettingsService.shared, engine: GachaEngine = GachaEngine(),
         player: MusicLibraryPlaying = MusicAppleScriptBridge(), timing: GachaTiming = GachaTiming()) {
        self.settingsService = settingsService
        self.player = player
        self.timing = timing
        self.engine = engine
        preferences = settingsService.loadSettings().gachaPreferences
    }

    var weather: WeatherSnapshot { preferences.snapshot() }

    func update(_ change: (inout GachaPreferences) -> Void) {
        change(&preferences)
        var settings = settingsService.loadSettings()
        settings.gachaPreferences = preferences
        do { try settingsService.saveSettings(settings) } catch {
            AppLogger.warning("Failed to save gacha preferences. error=\(error)")
        }
    }

    /// Called when the card appears; a round in progress is left alone.
    func startIfIdle() {
        if phase == .idle { startRound() }
    }

    /// "Again": interrupts whatever is going on (pausing a song this round
    /// started) and begins the next round.
    func startRound() {
        let interrupting = phase.chosenID != nil && track != nil
        cancelTasks()
        if interrupting { pauseMusic() }
        track = nil
        isAudible = false
        cards = engine.draw(weather: weather, pity: &pity, using: &rng)
        AppLogger.info("Gacha drawn. cards=\(cards.map(\.id).joined(separator: ",")) pity=\(pity)")
        flowTask = Task { [weak self] in
            guard let self else { return }
            for n in stride(from: 3, through: 1, by: -1) {
                self.phase = .countdown(n)
                guard await self.sleep(self.timing.countdownStep) else { return }
            }
            guard await self.sleep(self.timing.countdownBow) else { return }
            self.phase = .choosing
        }
    }

    func choose(_ card: GachaCard) {
        guard phase == .choosing, cards.contains(card) else { return }
        phase = .picking(card.id)
        let keywords = card.genreKeywords
        flowTask = Task { [weak self] in
            guard let self else { return }
            let picked = await self.run { try $0.pickRandomTrack(genreKeywords: keywords) }
            guard await self.sleep(self.timing.shatter) else { return }
            switch picked {
            case .success(let track?):
                self.track = track
                self.phase = .revealed(card.id)
            case .success(nil): self.phase = .failed(.libraryEmpty)
            case .failure(let error): self.phase = .failed(Self.failure(for: error))
            }
        }
    }

    func play() {
        guard case .revealed(let id) = phase, let track else { return }
        flowTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.run { try $0.play(persistentID: track.persistentID) }
            guard !Task.isCancelled else { return }
            if case .failure(let error) = result {
                self.phase = .failed(Self.failure(for: error))
                return
            }
            self.phase = .playing(id)
            self.isAudible = true
            self.monitor(track: track, id: id)
        }
    }

    // MARK: - Private

    /// Ends the round when the song finishes. Music keeps going to the next
    /// library track on its own, so the end is caught just before it and the
    /// player is paused.
    private func monitor(track: PickedTrack, id: String) {
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var polls = 0
            while !Task.isCancelled {
                guard await self.sleep(self.timing.pollInterval) else { return }
                polls += 1
                let result = await self.run { try $0.currentTrack() }
                guard !Task.isCancelled else { return }
                let now = (try? result.get()) ?? nil
                if let now {
                    let same = now.title == track.title && now.artist == track.artist
                    let nearEnd = now.duration > 0 && now.duration - now.position < 1
                    if !same || nearEnd {
                        if now.isPlaying { _ = await self.run { try $0.pausePlayback() } }
                        self.finish(id: id)
                        return
                    }
                    self.isAudible = now.isPlaying
                } else if polls > self.timing.startGracePolls {
                    self.finish(id: id)
                    return
                }
            }
        }
    }

    private func finish(id: String) {
        isAudible = false
        phase = .finished(id)
    }

    private func pauseMusic() {
        let player = player
        player.queue.async { try? player.pausePlayback() }
    }

    private func cancelTasks() {
        flowTask?.cancel()
        monitorTask?.cancel()
        flowTask = nil
        monitorTask = nil
    }

    /// false when cancelled.
    private func sleep(_ seconds: TimeInterval) async -> Bool {
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        return !Task.isCancelled
    }

    /// Runs a bridge call on the bridge's serial queue.
    private func run<T>(_ work: @escaping (MusicLibraryPlaying) throws -> T) async -> Result<T, Error> {
        let player = player
        return await withCheckedContinuation { continuation in
            player.queue.async { continuation.resume(returning: Result { try work(player) }) }
        }
    }

    private static func failure(for error: Error) -> GachaFailure {
        switch error as? MediaBridgeError {
        case .notAuthorized: return .needsAuthorization
        case .notRunning: return .musicNotRunning
        default: return .failed
        }
    }
}
