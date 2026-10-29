import XCTest
@testable import Switchly

/// Deterministic SplitMix64 so draws are reproducible.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class GachaEngineTests: XCTestCase {
    private let rainy = WeatherSnapshot(condition: .rain, temperatureCelsius: 10, windSpeedKmh: 8, season: .autumn)

    func testSeasonFromDateAndHemisphere() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let jan = cal.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        XCTAssertEqual(Season.of(jan, calendar: cal), .winter)
        XCTAssertEqual(Season.of(jan, southernHemisphere: true, calendar: cal), .summer)
        let dec = cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        XCTAssertEqual(Season.of(dec, calendar: cal), .winter)
    }

    func testDrawReturnsOneCardPerKind() {
        var rng = SeededRNG(state: 1)
        var pity = 0
        let cards = GachaEngine().draw(weather: rainy, pity: &pity, using: &rng)
        XCTAssertEqual(cards.map(\.kind), GachaCardKind.allCases)
    }

    func testSameSeedIsReproducible() {
        var a = SeededRNG(state: 42), b = SeededRNG(state: 42)
        var pa = 0, pb = 0
        XCTAssertEqual(GachaEngine().draw(weather: rainy, pity: &pa, using: &a),
                       GachaEngine().draw(weather: rainy, pity: &pb, using: &b))
    }

    func testPityGuaranteesRareAndResets() {
        var engine = GachaEngine()
        engine.rareChance = 0
        engine.epicChance = 0
        var rng = SeededRNG(state: 7)
        var pity = engine.pityThreshold
        let cards = engine.draw(weather: rainy, pity: &pity, using: &rng)
        XCTAssertTrue(cards.contains { $0.rarity >= .rare })
        XCTAssertEqual(pity, 0)
    }

    func testPityCountsUpWithoutRare() {
        var engine = GachaEngine()
        engine.rareChance = 0
        engine.epicChance = 0
        var rng = SeededRNG(state: 7)
        var pity = 0
        _ = engine.draw(weather: rainy, pity: &pity, using: &rng)
        XCTAssertEqual(pity, 1)
    }

    func testWeatherBiasesPicks() {
        var engine = GachaEngine()
        engine.rareChance = 0
        engine.epicChance = 0
        var rng = SeededRNG(state: 3)
        var pity = 0
        var lofi = 0
        for _ in 0..<300 {
            let genre = engine.draw(weather: rainy, pity: &pity, using: &rng).first { $0.kind == .genre }!
            if genre.id == "genre.lofi" { lofi += 1 }
        }
        // lofi fits rain; jazz/pop are off-weather or only season-fit → lofi should dominate commons.
        XCTAssertGreaterThan(lofi, 100)
    }

    func testEveryKindHasEveryRarity() {
        for kind in GachaCardKind.allCases {
            for rarity in GachaRarity.allCases {
                XCTAssertTrue(GachaCardPool.all.contains { $0.card.kind == kind && $0.card.rarity == rarity },
                              "\(kind) \(rarity) empty")
            }
        }
    }

    func testCardIdsUnique() {
        let ids = GachaCardPool.all.map(\.card.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
