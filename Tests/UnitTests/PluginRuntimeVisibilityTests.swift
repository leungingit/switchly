import XCTest
@testable import Switchly

final class PluginRuntimeVisibilityTests: XCTestCase {
    func testSharedRuntimeKeepsOtherConsumerActiveAndMultiplexesInvalidation() async {
        let visibility = PluginRuntimeVisibility()
        let runtime = VisibleTestRuntime()
        let firstEvent = expectation(description: "first listener")
        let secondEvent = expectation(description: "second listener")
        secondEvent.expectedFulfillmentCount = 2
        let first = visibility.acquire([runtime]) { firstEvent.fulfill() }
        let second = visibility.acquire([runtime]) { secondEvent.fulfill() }
        XCTAssertEqual(runtime.resumes, 1)
        runtime.onInvalidate?()
        await fulfillment(of: [firstEvent], timeout: 1)
        // 第一轮第二位消费者也已接到通知后，再开始下一轮，避免合并语义影响计数。
        try? await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        XCTAssertEqual(runtime.suspends, 0)
        XCTAssertNotNil(runtime.onInvalidate)
        runtime.onInvalidate?()
        await fulfillment(of: [secondEvent], timeout: 1)
        second.cancel()
        XCTAssertEqual(runtime.suspends, 1)
        XCTAssertNil(runtime.onInvalidate)
    }

    func testResetAndStaleLeaseDoNotSuspendNewConsumer() {
        let visibility = PluginRuntimeVisibility()
        let runtime = VisibleTestRuntime()
        let old = visibility.acquire([runtime]) {}
        visibility.reset()
        let current = visibility.acquire([runtime]) {}
        old.cancel()
        XCTAssertEqual(runtime.resumes, 2)
        XCTAssertEqual(runtime.suspends, 1)
        current.cancel()
        XCTAssertEqual(runtime.suspends, 2)
    }
}

private final class VisibleTestRuntime: PluginRuntimeProtocol {
    let manifest = PluginManifest(id: "com.example.visible", name: ["en": "Visible"], version: "1", apiVersion: 1,
                                  matches: ["com.apple.Music"], permissions: [], entry: "main.js", refreshInterval: nil)
    var onInvalidate: (() -> Void)?
    var resumes = 0
    var suspends = 0
    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> { .success([]) }
    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> { .success(()) }
    func resume() { resumes += 1 }
    func suspend() { suspends += 1 }
    func unmount() {}
}
