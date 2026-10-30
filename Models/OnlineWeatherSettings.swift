//
//  OnlineWeatherSettings.swift
//  Switchly
//
//  Optional online weather for the gacha. Switchly promises to run fully
//  locally (PRIVACY_POLICY §1); this is the single, opt-in exception: one HTTPS
//  GET to the weather service the user configures, only while the source is
//  set to online, at most once every 15 minutes. Plugins never make requests
//  themselves — they read the snapshot the host already fetched.
//

import Foundation

enum WeatherSourceMode: String, Codable {
    case manual, online
}

struct OnlineWeatherSettings: Equatable, Codable {
    /// Default endpoint speaks the OpenWeatherMap "current weather" shape.
    static let defaultEndpoint = "https://api.openweathermap.org/data/2.5/weather"
    /// Refresh floor; also the age after which a cached reading is dropped.
    static let refreshInterval: TimeInterval = 15 * 60
    static let maximumAge: TimeInterval = 30 * 60

    var mode: WeatherSourceMode = .manual
    var endpoint = OnlineWeatherSettings.defaultEndpoint
    /// City name passed to the service ("q=" for OpenWeatherMap).
    var city = ""
    /// Stored with the rest of the settings; never written to logs.
    var apiKey = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(WeatherSourceMode.self, forKey: .mode)) ?? .manual
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? Self.defaultEndpoint
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    /// HTTPS only, so a key never travels in clear text.
    var requestURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    var isReady: Bool {
        mode == .online && requestURL != nil
            && !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
