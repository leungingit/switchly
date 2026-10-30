import XCTest
@testable import Switchly

private final class FakeFetcher: WeatherFetching, @unchecked Sendable {
    var result: Result<WeatherReading, Error> = .success(WeatherReading(condition: "rain", temperatureCelsius: 9,
                                                                       windSpeedKmh: 12, fetchedAt: Date()))
    private(set) var calls = 0
    var onFetch: (() -> Void)?

    func fetch(_ settings: OnlineWeatherSettings) async throws -> WeatherReading {
        calls += 1
        onFetch?()
        return try result.get()
    }
}

final class OnlineWeatherTests: XCTestCase {
    private func forecast(code: Int, temp: Double = 9, wind: Double = 12) -> Data {
        Data(#"{"current":{"temperature_2m":\#(temp),"weather_code":\#(code),"wind_speed_10m":\#(wind)}}"#.utf8)
    }

    func testMapsWMOCodes() {
        let cases: [(Int, String)] = [(0, "clear"), (1, "cloudy"), (3, "cloudy"), (45, "fog"), (48, "fog"),
                                      (51, "rain"), (61, "rain"), (65, "rain"), (71, "snow"), (77, "snow"),
                                      (80, "rain"), (85, "snow"), (95, "storm"), (99, "storm")]
        for (code, expected) in cases {
            XCTAssertEqual(WeatherMapper.condition(forWMOCode: code), expected, "code \(code)")
        }
    }

    func testMapsForecastToReading() throws {
        let reading = try WeatherMapper.reading(fromForecast: forecast(code: 61, temp: -3.5, wind: 14.4), at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(reading.condition, "rain")
        XCTAssertEqual(reading.temperatureCelsius, -3.5)
        XCTAssertEqual(reading.windSpeedKmh, 14.4)
        XCTAssertEqual(reading.jsObject["source"] as? String, "online")
    }

    func testMapsGeocodingResult() throws {
        let data = Data(#"{"results":[{"latitude":31.22,"longitude":121.46}]}"#.utf8)
        let found = try WeatherMapper.coordinates(fromGeocoding: data)
        XCTAssertEqual(found.latitude, 31.22)
        XCTAssertEqual(found.longitude, 121.46)
        XCTAssertThrowsError(try WeatherMapper.coordinates(fromGeocoding: Data(#"{"results":[]}"#.utf8)))
    }

    func testRejectsMalformedPayload() {
        XCTAssertThrowsError(try WeatherMapper.reading(fromForecast: Data("[]".utf8), at: Date()))
        XCTAssertThrowsError(try WeatherMapper.reading(fromForecast: Data(#"{"current":{"weather_code":0}}"#.utf8), at: Date()),
                             "temperature is required")
    }

    func testSettingsRequireHTTPSAndCompleteFields() {
        var settings = OnlineWeatherSettings()
        XCTAssertFalse(settings.enabled, "off by default")
        XCTAssertFalse(settings.isReady)

        settings.enabled = true
        XCTAssertFalse(settings.isReady, "no city yet")
        settings.place = "   "
        XCTAssertFalse(settings.isReady, "blank city")
        settings.place = "Shanghai"
        XCTAssertTrue(settings.isReady)
        XCTAssertEqual(settings.trimmedPlace, "Shanghai")
        XCTAssertTrue(OnlineWeatherSettings.geocodingEndpoint.hasPrefix("https://"))
        XCTAssertTrue(OnlineWeatherSettings.forecastEndpoint.hasPrefix("https://"))
    }

    func testSettingsSurviveOlderData() throws {
        var settings = AppSettings.default
        settings.onlineWeather.enabled = true
        settings.onlineWeather.place = "Shanghai"
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded.onlineWeather, settings.onlineWeather)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "onlineWeather")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: old).onlineWeather.enabled)
    }

    func testServiceFetchesOncePerIntervalAndExpires() async throws {
        let fetcher = FakeFetcher()
        var snapshot = OnlineWeatherSettings()
        snapshot.enabled = true
        snapshot.place = "Shanghai"
        let service = OnlineWeatherService(fetcher: fetcher, settings: { snapshot })

        let fetched = expectation(description: "fetched")
        fetcher.onFetch = { fetched.fulfill() }
        XCTAssertNil(service.current(), "the first read only starts the request")
        await fulfillment(of: [fetched], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetcher.calls, 1)
        XCTAssertEqual(service.current()?.condition, "rain", "then it serves the cache")

        XCTAssertNotNil(service.current(), "a second read reuses the cache")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fetcher.calls, 1, "still inside the 15-minute floor")

        service.store(WeatherReading(condition: "clear", temperatureCelsius: 1, windSpeedKmh: 2,
                                     fetchedAt: Date(timeIntervalSinceNow: -OnlineWeatherSettings.maximumAge - 60)))
        XCTAssertNil(service.current(), "readings older than the maximum age are dropped")
    }

    func testOfflineModeNeverFetches() async throws {
        let fetcher = FakeFetcher()
        let service = OnlineWeatherService(fetcher: fetcher, settings: { OnlineWeatherSettings() })
        XCTAssertNil(service.current())
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fetcher.calls, 0)
    }
}
