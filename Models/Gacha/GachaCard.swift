//
//  GachaCard.swift
//  Switchly
//
//  Card templates the engine draws from. Each template maps a sensory
//  feeling to genre keywords later matched against the Music library.
//

import Foundation

enum GachaCardKind: String, CaseIterable, Codable {
    case mood, genre, scene
}

enum GachaRarity: Int, CaseIterable, Codable, Comparable {
    case common, rare, epic
    static func < (a: GachaRarity, b: GachaRarity) -> Bool { a.rawValue < b.rawValue }
}

struct GachaCard: Equatable, Codable, Identifiable {
    let id: String
    let kind: GachaCardKind
    let rarity: GachaRarity
    /// Lowercased substrings matched against a track's genre.
    let genreKeywords: [String]
}

/// A card plus the weather it fits. nil constraint = fits anything.
struct GachaCardTemplate {
    let card: GachaCard
    var conditions: Set<WeatherCondition>?
    var seasons: Set<Season>?
    var temperature: ClosedRange<Double>?
    var wind: ClosedRange<Double>?

    func fits(_ w: WeatherSnapshot) -> Bool {
        (conditions?.contains(w.condition) ?? true)
            && (seasons?.contains(w.season) ?? true)
            && (temperature?.contains(w.temperatureCelsius) ?? true)
            && (wind?.contains(w.windSpeedKmh) ?? true)
    }
}
