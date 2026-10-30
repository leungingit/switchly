//
//  OnlineWeatherService.swift
//  Switchly
//
//  Host half of the opt-in online weather, backed by Open-Meteo (free, no API
//  key). Two requests at most per refresh: a geocoding lookup when the place
//  changed, then the forecast. Results live in memory only; plugins read them
//  through `ctx.weather` and never see the requests.
//

import Foundation

/// What the gacha needs from a weather service.
struct WeatherReading: Equatable {
    /// gacha condition: clear / cloudy / rain / snow / fog / storm.
    let condition: String
    let temperatureCelsius: Double
    let windSpeedKmh: Double
    let fetchedAt: Date

    var jsObject: [String: Any] {
        ["condition": condition, "temperature": temperatureCelsius, "wind": windSpeedKmh, "source": "online"]
    }
}

enum OnlineWeatherError: Error, Equatable {
    case notConfigured
    case placeNotFound
    case badResponse(Int)
    case malformed
}

protocol WeatherFetching: AnyObject, Sendable {
    func fetch(_ settings: OnlineWeatherSettings) async throws -> WeatherReading
}

final class OpenMeteoWeatherFetcher: WeatherFetching, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    /// Geocoding is cached per place, so the usual refresh is a single request.
    private var resolved: (place: String, latitude: Double, longitude: Double)?

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetch(_ settings: OnlineWeatherSettings) async throws -> WeatherReading {
        let place = settings.trimmedPlace
        guard !place.isEmpty else { throw OnlineWeatherError.notConfigured }
        let coordinates = try await coordinates(for: place)
        var components = try components(for: OnlineWeatherSettings.forecastEndpoint)
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinates.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinates.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let data = try await get(components)
        return try WeatherMapper.reading(fromForecast: data, at: Date())
    }

    private func coordinates(for place: String) async throws -> (latitude: Double, longitude: Double) {
        if let cached = cachedCoordinates(for: place) { return cached }

        var components = try components(for: OnlineWeatherSettings.geocodingEndpoint)
        components.queryItems = [
            URLQueryItem(name: "name", value: place),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let data = try await get(components)
        let found = try WeatherMapper.coordinates(fromGeocoding: data)
        storeCoordinates(place: place, latitude: found.latitude, longitude: found.longitude)
        return found
    }

    private func get(_ components: URLComponents) async throws -> Data {
        guard let url = components.url else { throw OnlineWeatherError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let started = DispatchTime.now()
        let (data, response) = try await session.data(for: request)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // URL-safe logging: Open-Meteo takes no secret, but keep it to the host.
            AppLogger.warning("Online weather rejected. status=\(status) host=\(url.host ?? "?") ms=\(String(format: "%.0f", ms))")
            throw OnlineWeatherError.badResponse(status)
        }
        AppLogger.info("Online weather request. host=\(url.host ?? "?") ms=\(String(format: "%.0f", ms))")
        return data
    }

    private func cachedCoordinates(for place: String) -> (latitude: Double, longitude: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let resolved, resolved.place == place else { return nil }
        return (resolved.latitude, resolved.longitude)
    }

    private func storeCoordinates(place: String, latitude: Double, longitude: Double) {
        lock.lock(); resolved = (place, latitude, longitude); lock.unlock()
    }

    private func components(for string: String) throws -> URLComponents {
        guard let components = URLComponents(string: string) else { throw OnlineWeatherError.notConfigured }
        return components
    }
}

enum WeatherMapper {
    /// Open-Meteo forecast: `{"current":{"temperature_2m":…,"weather_code":…,"wind_speed_10m":…}}`.
    static func reading(fromForecast data: Data, at date: Date) throws -> WeatherReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int else { throw OnlineWeatherError.malformed }
        let wind = (current["wind_speed_10m"] as? Double) ?? 0
        return WeatherReading(condition: condition(forWMOCode: code),
                              temperatureCelsius: temperature,
                              windSpeedKmh: wind,
                              fetchedAt: date)
    }

    /// Open-Meteo geocoding: `{"results":[{"latitude":…,"longitude":…}]}`.
    static func coordinates(fromGeocoding data: Data) throws -> (latitude: Double, longitude: Double) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let latitude = first["latitude"] as? Double,
              let longitude = first["longitude"] as? Double else { throw OnlineWeatherError.placeNotFound }
        return (latitude, longitude)
    }

    /// WMO 4677 weather codes, as Open-Meteo reports them.
    static func condition(forWMOCode code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2, 3: return "cloudy"
        case 45, 48: return "fog"
        case 51...57, 61...67, 80...82: return "rain"
        case 71...77, 85, 86: return "snow"
        case 95...99: return "storm"
        default: return "cloudy"
        }
    }
}

/// Cache and refresh policy. `current()` is safe to call from any queue and
/// never blocks on the network.
final class OnlineWeatherService: @unchecked Sendable {
    static let shared = OnlineWeatherService()

    private let fetcher: WeatherFetching
    private let settings: () -> OnlineWeatherSettings
    private let lock = NSLock()
    private var cache: WeatherReading?
    private var lastAttempt = Date.distantPast
    private var isRefreshing = false

    init(fetcher: WeatherFetching = OpenMeteoWeatherFetcher(),
         settings: @escaping () -> OnlineWeatherSettings = { SettingsService.shared.loadSettings().onlineWeather }) {
        self.fetcher = fetcher
        self.settings = settings
    }

    /// Freshest reading, or nil when off / unconfigured / stale.
    func current() -> WeatherReading? {
        let snapshot = settings()
        guard snapshot.isReady else { return nil }
        refreshIfNeeded(snapshot)
        lock.lock()
        defer { lock.unlock() }
        guard let cache, Date().timeIntervalSince(cache.fetchedAt) <= OnlineWeatherSettings.maximumAge else { return nil }
        return cache
    }

    /// Cached value without ever starting a request (settings status line, tests).
    func cachedReading() -> WeatherReading? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// Called on panel show and when the source changes.
    func refreshIfNeeded() { refreshIfNeeded(settings()) }

    /// Ignores the refresh floor — explicit "refresh now", or edits to the place.
    func forceRefresh() {
        lock.lock(); lastAttempt = .distantPast; lock.unlock()
        refreshIfNeeded(settings())
    }

    private func refreshIfNeeded(_ snapshot: OnlineWeatherSettings) {
        guard snapshot.isReady, beginRefresh() else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reading = try await self.fetcher.fetch(snapshot)
                self.finishRefresh(with: reading)
                NotificationCenter.default.post(name: .onlineWeatherDidChange, object: nil)
            } catch {
                self.finishRefresh(with: nil)
                AppLogger.warning("Online weather unavailable. error=\(error)")
            }
        }
    }

    /// Locking lives in these synchronous helpers: NSLock is unavailable from
    /// async contexts under Swift 6.
    private func beginRefresh() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRefreshing, Date().timeIntervalSince(lastAttempt) >= OnlineWeatherSettings.refreshInterval else { return false }
        lastAttempt = Date()
        isRefreshing = true
        return true
    }

    private func finishRefresh(with reading: WeatherReading?) {
        lock.lock()
        isRefreshing = false
        if let reading { cache = reading }
        lock.unlock()
    }

    /// Test seam: replace the cached reading without touching the network.
    func store(_ reading: WeatherReading?) {
        lock.lock(); cache = reading; lock.unlock()
    }
}

extension Notification.Name {
    static let onlineWeatherDidChange = Notification.Name("com.switchly.onlineWeatherDidChange")
}
