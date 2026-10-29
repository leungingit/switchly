//
//  GachaCardPool.swift
//  Switchly
//
//  Built-in card templates. Card ids double as localization keys
//  ("gacha.card.<id>").
//

import Foundation

enum GachaCardPool {
    private static func t(_ id: String, _ kind: GachaCardKind, _ rarity: GachaRarity, _ keywords: [String],
                          conditions: Set<WeatherCondition>? = nil, seasons: Set<Season>? = nil,
                          temperature: ClosedRange<Double>? = nil, wind: ClosedRange<Double>? = nil) -> GachaCardTemplate {
        GachaCardTemplate(card: GachaCard(id: id, kind: kind, rarity: rarity, genreKeywords: keywords),
                          conditions: conditions, seasons: seasons, temperature: temperature, wind: wind)
    }

    static let all: [GachaCardTemplate] = [
        // Mood
        t("mood.calm", .mood, .common, ["ambient", "new age", "classical", "acoustic"], conditions: [.cloudy, .fog]),
        t("mood.cozy", .mood, .common, ["folk", "singer", "jazz"], temperature: -30...12),
        t("mood.bright", .mood, .common, ["pop", "dance"], conditions: [.clear], temperature: 18...50),
        t("mood.melancholy", .mood, .rare, ["indie", "alternative", "blues"], conditions: [.rain, .fog]),
        t("mood.euphoric", .mood, .epic, ["electronic", "house", "dance"], conditions: [.clear], seasons: [.summer]),
        t("mood.dramatic", .mood, .epic, ["soundtrack", "classical", "rock"], conditions: [.storm]),
        // Genre
        t("genre.lofi", .genre, .common, ["lo-fi", "chill", "hip-hop", "r&b"], conditions: [.rain, .cloudy]),
        t("genre.jazz", .genre, .common, ["jazz", "blues"], seasons: [.autumn, .winter]),
        t("genre.pop", .genre, .common, ["pop"], seasons: [.spring, .summer]),
        t("genre.rock", .genre, .rare, ["rock", "metal"], wind: 30...200),
        t("genre.classical", .genre, .rare, ["classical", "piano"], conditions: [.snow, .fog]),
        t("genre.electronic", .genre, .epic, ["electronic", "techno", "house"], temperature: 24...50),
        // Scene
        t("scene.rainyWindow", .scene, .common, ["jazz", "lo-fi", "acoustic", "singer"], conditions: [.rain]),
        t("scene.morningWalk", .scene, .common, ["pop", "folk", "indie"], conditions: [.clear], seasons: [.spring, .autumn]),
        t("scene.beachDrive", .scene, .rare, ["pop", "reggae", "dance", "rock"], seasons: [.summer], temperature: 25...50),
        t("scene.fireside", .scene, .rare, ["folk", "country", "acoustic"], seasons: [.winter], temperature: -30...8),
        t("scene.snowfall", .scene, .epic, ["classical", "soundtrack", "new age", "piano"], conditions: [.snow]),
        t("scene.windRider", .scene, .epic, ["rock", "electronic", "soundtrack"], wind: 40...200),
    ]
}
