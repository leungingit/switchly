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
    private func payload(code: Int, temp: Double = 9, wind: Double = 3) -> Data {
        Data(#"{"weather":[{"id":\#(code)}],"main":{"temp":\#(temp)},"wind":{"speed":\#(wind)}}"#.utf8)
    }

    func testMapsOpenWeatherCodes() throws {
        let cases: [(Int, String)] = [(211, "storm"), (300, "rain"), (501, "rain"), (601, "snow"),
                                      (701, "fog"), (800, "clear"), (802, "cloudy"), (804, "cloudy")]
        for (code, expected) in cases {
            XCTAssertEqual(WeatherMapper.condition(forCode: code), expected, "code \(code)")
        }
    }

    func testMapsPayloadToReading() throws {
        let reading = try WeatherMapper.reading(from: payload(code: 500, temp: -3.5, wind: 4), at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(reading.condition, "rain")
        XCTAssertEqual(reading.temperatureCelsius, -3.5)
        XCTAssertEqual(reading.windSpeedKmh, 14.4, accuracy: 0.0001, "m/s → km/h")
        XCTAssertEqual(reading.jsObject["source"] as? String, "online")
    }

    func testRejectsMalformedPayload() {
        XCTAssertThrowsError(try WeatherMapper.reading(from: Data("[]".utf8), at: Date()))
        XCTAssertThrowsError(try WeatherMapper.reading(from: Data(#"{"weather":[{"id":800}]}"#.utf8), at: Date()),
                             "temperature is required")
    }

    func testSettingsRequireHTTPSAndCompleteFields() {
        var settings = OnlineWeatherSettings()
        XCTAssertEqual(settings.mode, .manual)
        XCTAssertFalse(settings.isReady, "manual by default")

        settings.mode = .online
        XCTAssertFalse(settings.isReady, "no city or key yet")
        settings.city = "Shanghai"
        settings.apiKey = "k"
        XCTAssertTrue(settings.isReady)

        settings.endpoint = "http://example.com/weather"
        XCTAssertNil(settings.requestURL, "plain HTTP would leak the key")
        XCTAssertFalse(settings.isReady)

        settings.endpoint = "https://example.com/weather"
        XCTAssertTrue(settings.isReady)
    }

    func testSettingsSurviveOlderData() throws {
        var settings = AppSettings.default
        settings.onlineWeather.mode = .online
        settings.onlineWeather.city = "Shanghai"
        settings.onlineWeather.apiKey = "secret"
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded.onlineWeather, settings.onlineWeather)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "onlineWeather")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: old).onlineWeather.mode, .manual)
    }

    func testServiceFetchesOncePerIntervalAndExpires() async throws {
        let fetcher = FakeFetcher()
        var snapshot = OnlineWeatherSettings()
        snapshot.mode = .online
        snapshot.city = "Shanghai"
        snapshot.apiKey = "k"
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
