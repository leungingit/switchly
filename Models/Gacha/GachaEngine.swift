//
//  GachaEngine.swift
//  Switchly
//
//  Draws one card per kind (mood / genre / scene) for the current weather.
//  The caller owns the random source (inject a seeded one in tests) and the
//  pity counter.
//

import Foundation

struct GachaEngine {
    /// Rarity rolls in percent; the remainder is common.
    var epicChance = 5
    var rareChance = 25
    /// After this many draws without a rare-or-better card, the next draw
    /// guarantees at least one rare.
    var pityThreshold = 9
    /// Weight of templates that do not fit the weather, relative to 1.0 for
    /// fitting ones, so off-weather cards stay possible.
    var offWeatherWeight = 0.15
    var templates: [GachaCardTemplate] = GachaCardPool.all

    /// Returns one card per kind, in `GachaCardKind.allCases` order.
    func draw<G: RandomNumberGenerator>(weather: WeatherSnapshot, pity: inout Int, using rng: inout G) -> [GachaCard] {
        var cards = GachaCardKind.allCases.compactMap { kind -> GachaCard? in
            let rarity = rollRarity(using: &rng)
            return pick(kind: kind, rarity: rarity, weather: weather, using: &rng)
        }
        if cards.contains(where: { $0.rarity >= .rare }) {
            pity = 0
        } else if pity >= pityThreshold, let index = cards.indices.randomElement(using: &rng),
                  let upgraded = pick(kind: cards[index].kind, rarity: .rare, weather: weather, using: &rng),
                  upgraded.rarity >= .rare {
            cards[index] = upgraded
            pity = 0
        } else {
            pity += 1
        }
        return cards
    }

    private func rollRarity<G: RandomNumberGenerator>(using rng: inout G) -> GachaRarity {
        let roll = Int.random(in: 0..<100, using: &rng)
        if roll < epicChance { return .epic }
        if roll < epicChance + rareChance { return .rare }
        return .common
    }

    /// Weighted pick among the kind's templates of `rarity`; falls back to the
    /// nearest lower rarity, then any rarity, when the tier is empty.
    private func pick<G: RandomNumberGenerator>(kind: GachaCardKind, rarity: GachaRarity,
                                                 weather: WeatherSnapshot, using rng: inout G) -> GachaCard? {
        let ofKind = templates.filter { $0.card.kind == kind }
        var tier = rarity
        var pool = ofKind.filter { $0.card.rarity == tier }
        while pool.isEmpty, let lower = GachaRarity(rawValue: tier.rawValue - 1) {
            tier = lower
            pool = ofKind.filter { $0.card.rarity == tier }
        }
        if pool.isEmpty { pool = ofKind }
        guard !pool.isEmpty else { return nil }
        let weights = pool.map { $0.fits(weather) ? 1.0 : offWeatherWeight }
        var target = Double.random(in: 0..<weights.reduce(0, +), using: &rng)
        for (template, weight) in zip(pool, weights) {
            if target < weight { return template.card }
            target -= weight
        }
        return pool.last?.card
    }
}
