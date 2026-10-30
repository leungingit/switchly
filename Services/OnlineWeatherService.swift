//
//  OnlineWeatherService.swift
//  Switchly
//
//  The host-side half of the opt-in online weather: one HTTPS GET per refresh
//  interval, a small in-memory cache, and a mapping from the service's payload
//  to the four values the gacha needs. Plugins only ever read `current()`.
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
    case badResponse(Int)
    case malformed
}

protocol WeatherFetching: AnyObject, Sendable {
    func fetch(_ settings: OnlineWeatherSettings) async throws -> WeatherReading
}

/// OpenWeatherMap "current weather" (units=metric), also the shape any
/// compatible service returns.
final class URLSessionWeatherFetcher: WeatherFetching, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetch(_ settings: OnlineWeatherSettings) async throws -> WeatherReading {
        guard let base = settings.requestURL else { throw OnlineWeatherError.notConfigured }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw OnlineWeatherError.notConfigured }
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "q", value: settings.city.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "appid", value: settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "units", value: "metric"),
        ])
        components.queryItems = items
        guard let url = components.url else { throw OnlineWeatherError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let started = DispatchTime.now()
        let (data, response) = try await session.data(for: request)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Host only: the URL carries the key.
            AppLogger.warning("Online weather rejected. status=\(status) host=\(base.host ?? "?") ms=\(String(format: "%.0f", ms))")
            throw OnlineWeatherError.badResponse(status)
        }
        let reading = try WeatherMapper.reading(from: data, at: Date())
        AppLogger.info("Online weather fetched. condition=\(reading.condition) ms=\(String(format: "%.0f", ms))")
        return reading
    }
}

enum WeatherMapper {
    /// Maps an OpenWeatherMap-style payload. Kept pure so it is unit-tested.
    static func reading(from data: Data, at date: Date) throws -> WeatherReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = root["main"] as? [String: Any],
              let temperature = main["temp"] as? Double else { throw OnlineWeatherError.malformed }
        let code = ((root["weather"] as? [[String: Any]])?.first?["id"] as? Int) ?? 800
        let wind = ((root["wind"] as? [String: Any])?["speed"] as? Double).map { $0 * 3.6 } ?? 0
        return WeatherReading(condition: condition(forCode: code),
                              temperatureCelsius: temperature,
                              windSpeedKmh: wind,
                              fetchedAt: date)
    }

    static func condition(forCode code: Int) -> String {
        switch code {
        case 200..<300: return "storm"
        case 300..<600: return "rain"
        case 600..<700: return "snow"
        case 700..<800: return "fog"
        case 800: return "clear"
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

    init(fetcher: WeatherFetching = URLSessionWeatherFetcher(),
         settings: @escaping () -> OnlineWeatherSettings = { SettingsService.shared.loadSettings().onlineWeather }) {
        self.fetcher = fetcher
        self.settings = settings
    }

    /// Freshest reading, or nil when offline / unconfigured / stale.
    func current() -> WeatherReading? {
        let snapshot = settings()
        guard snapshot.isReady else { return nil }
        refreshIfNeeded(snapshot)
        lock.lock()
        defer { lock.unlock() }
        guard let cache, Date().timeIntervalSince(cache.fetchedAt) <= OnlineWeatherSettings.maximumAge else { return nil }
        return cache
    }

    /// Cached value without ever starting a request (tests, settings preview).
    func cachedReading() -> WeatherReading? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// Called on panel show and when the source changes.
    func refreshIfNeeded() { refreshIfNeeded(settings()) }

    /// Ignores the refresh floor — for the settings page's explicit action and
    /// for edits to the endpoint / city / key.
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

    /// Locking lives in these two synchronous helpers: NSLock is unavailable
    /// from async contexts under Swift 6.
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
