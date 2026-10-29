//
//  GachaPreferences.swift
//  Switchly
//
//  User-entered weather for the gacha. Season is derived from the date, so
//  it is not stored.
//

import Foundation

struct GachaPreferences: Equatable, Codable {
    var condition: WeatherCondition = .clear
    var temperatureCelsius: Double = 20
    var windSpeedKmh: Double = 10
    var southernHemisphere = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        condition = (try? c.decodeIfPresent(WeatherCondition.self, forKey: .condition)) ?? .clear
        temperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .temperatureCelsius) ?? 20
        windSpeedKmh = try c.decodeIfPresent(Double.self, forKey: .windSpeedKmh) ?? 10
        southernHemisphere = try c.decodeIfPresent(Bool.self, forKey: .southernHemisphere) ?? false
    }

    func snapshot(on date: Date = Date()) -> WeatherSnapshot {
        WeatherSnapshot(condition: condition, temperatureCelsius: temperatureCelsius, windSpeedKmh: windSpeedKmh,
                        season: .of(date, southernHemisphere: southernHemisphere))
    }
}
