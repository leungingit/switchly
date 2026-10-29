//
//  WeatherSnapshot.swift
//  Switchly
//
//  Sensory inputs of the weather gacha: condition, temperature, wind, season.
//

import Foundation

enum WeatherCondition: String, CaseIterable, Codable {
    case clear, cloudy, rain, snow, fog, storm
}

enum Season: String, CaseIterable, Codable {
    case spring, summer, autumn, winter

    /// Meteorological seasons. `southernHemisphere` flips them.
    static func of(_ date: Date, southernHemisphere: Bool = false, calendar: Calendar = .current) -> Season {
        let month = calendar.component(.month, from: date)
        let northern: Season
        switch month {
        case 3...5: northern = .spring
        case 6...8: northern = .summer
        case 9...11: northern = .autumn
        default: northern = .winter
        }
        guard southernHemisphere else { return northern }
        switch northern {
        case .spring: return .autumn
        case .summer: return .winter
        case .autumn: return .spring
        case .winter: return .summer
        }
    }
}

struct WeatherSnapshot: Equatable, Codable {
    var condition: WeatherCondition
    var temperatureCelsius: Double
    var windSpeedKmh: Double
    var season: Season
}

/// Source of the current weather. Implementations: manual input (default),
/// simulated, and later an optional network provider.
protocol WeatherProviding: Sendable {
    func currentWeather() async throws -> WeatherSnapshot
}

/// Offline default: returns whatever the user picked in the gacha panel.
struct ManualWeatherProvider: WeatherProviding {
    var snapshot: WeatherSnapshot
    func currentWeather() async throws -> WeatherSnapshot { snapshot }
}
