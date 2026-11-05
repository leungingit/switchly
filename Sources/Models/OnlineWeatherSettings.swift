//
//  OnlineWeatherSettings.swift
//  Switchly
//
//  Optional online weather for the gacha. Switchly promises to run fully
//  locally (PRIVACY_POLICY §1); this is the single, opt-in exception: Open-Meteo
//  (free, no API key) answers two HTTPS GETs — one geocoding lookup per place,
//  one forecast — and only while the switch is on, at most every 15 minutes.
//  Plugins never make requests; they read the snapshot the host fetched.
//

import Foundation

struct OnlineWeatherSettings: Equatable, Codable {
    /// Free, no key required; the host owns the URLs so plugins cannot redirect them.
    static let geocodingEndpoint = "https://geocoding-api.open-meteo.com/v1/search"
    static let forecastEndpoint = "https://api.open-meteo.com/v1/forecast"
    /// Refresh floor; readings older than `maximumAge` are ignored.
    static let refreshInterval: TimeInterval = 15 * 60
    static let maximumAge: TimeInterval = 30 * 60

    /// Off by default: the fully local manual weather applies until turned on.
    var enabled = false
    /// City name, e.g. "Shanghai" or "上海".
    var place = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
    }

    var trimmedPlace: String { place.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isReady: Bool { enabled && !trimmedPlace.isEmpty }
}
