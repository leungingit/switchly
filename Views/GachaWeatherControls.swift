//
//  GachaWeatherControls.swift
//  Switchly
//
//  Manual weather inputs, shared by the Dock preview gacha card and Preferences → Plugins.
//

import SwiftUI

struct GachaWeatherControls: View {
    @Binding var preferences: GachaPreferences
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Picker(t("Weather"), selection: $preferences.condition) {
                ForEach(WeatherCondition.allCases, id: \.self) { condition in
                    Label(t(condition.titleKey), systemImage: condition.symbol).tag(condition)
                }
            }
            Stepper(value: $preferences.temperatureCelsius, in: -40...50, step: 1) {
                Text("\(t("Temperature")): \(Int(preferences.temperatureCelsius)) °C")
            }
            Stepper(value: $preferences.windSpeedKmh, in: 0...150, step: 5) {
                Text("\(t("Wind speed")): \(Int(preferences.windSpeedKmh)) km/h")
            }
            Toggle(t("Southern hemisphere seasons"), isOn: $preferences.southernHemisphere)
            Text("\(t("Season")): \(t(Season.of(Date(), southernHemisphere: preferences.southernHemisphere).titleKey))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func t(_ key: String) -> String { language.localizedString(key) }
}

extension WeatherCondition {
    var titleKey: String { "gacha.weather.\(rawValue)" }
    var symbol: String {
        switch self {
        case .clear: return "sun.max"
        case .cloudy: return "cloud"
        case .rain: return "cloud.rain"
        case .snow: return "snow"
        case .fog: return "cloud.fog"
        case .storm: return "cloud.bolt"
        }
    }
}

extension Season {
    var titleKey: String { "gacha.season.\(rawValue)" }
}
