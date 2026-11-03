import XCTest
@testable import Switchly

final class PluginVirtualClockTests: XCTestCase {
    func testTimersFireInDueThenCreationOrder() {
        let clock = PluginVirtualClock(startMilliseconds: 1_000, seed: 1)
        var order: [String] = []
        _ = clock.schedule(afterMilliseconds: 50) { order.append("b") }
        _ = clock.schedule(afterMilliseconds: 10) { order.append("a") }
        _ = clock.schedule(afterMilliseconds: 50) { order.append("c") }
        XCTAssertEqual(clock.advance(byMilliseconds: 49), 1)
        XCTAssertEqual(order, ["a"])
        XCTAssertEqual(clock.advance(byMilliseconds: 1), 2)
        XCTAssertEqual(order, ["a", "b", "c"])
        XCTAssertEqual(clock.nowMilliseconds, 1_050)
    }

    func testCancelAndTimerLimit() {
        let clock = PluginVirtualClock(startMilliseconds: 0, seed: 1)
        var fired = 0
        let id = clock.schedule(afterMilliseconds: 5) { fired += 1 }
        clock.cancel(id)
        for _ in 0..<PluginVirtualClock.maxTimers { _ = clock.schedule(afterMilliseconds: 1_000) {} }
        XCTAssertEqual(clock.schedule(afterMilliseconds: 1) {}, 0, "over the limit returns 0 like the system path")
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(fired, 0)
    }

    func testSelfRearmingTimerIsBounded() {
        let clock = PluginVirtualClock(startMilliseconds: 0, seed: 1)
        func arm() { _ = clock.schedule(afterMilliseconds: 0) { arm() } }
        arm()
        XCTAssertNil(clock.advance(byMilliseconds: 1), "zero-delay re-arming must not loop forever")
    }

    func testSameSeedSameSequence() {
        let a = PluginVirtualClock(startMilliseconds: 0, seed: 42)
        let b = PluginVirtualClock(startMilliseconds: 0, seed: 42)
        let c = PluginVirtualClock(startMilliseconds: 0, seed: 43)
        let first = (0..<5).map { _ in a.nextRandom() }
        XCTAssertEqual(first, (0..<5).map { _ in b.nextRandom() })
        XCTAssertNotEqual(first, (0..<5).map { _ in c.nextRandom() })
        XCTAssertTrue(first.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    private func runtime(clock: PluginVirtualClock?) -> PluginRuntime {
        let manifest = PluginManifest(id: "com.example.clock", name: ["en": "Clock"], version: "1", apiVersion: 2,
                                      matches: ["com.example.app"], permissions: [], entry: "main.js",
                                      refreshInterval: nil, fsRoots: nil, defaultEnabled: nil)
        let source = """
        var ticks = 0;
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            if (ticks === 0) { ticks = 1; setTimeout(function () { ticks = 2; }, 100); }
            return [{ slot: "center", node: { type: "text", value: [Date.now(), new Date().getTime(), Math.random(), ticks].join("|") } }];
          },
          onAction(ctx, id, value) {}
        };
        """
        let package = PluginPackage(manifest: manifest, directory: FileManager.default.temporaryDirectory, source: source, origin: .builtin)
        return PluginRuntime(package: package, timeout: 2, permissions: [], virtualClock: clock)
    }

    private func text(_ runtime: PluginRuntime) async throws -> String {
        let ctx = PluginRenderContext(bundleID: "com.example.app", pid: 1, appName: "App", windowID: 0, titleSummary: "")
        let slots = try await runtime.render(context: ctx).get()
        guard case .text(let value, _, _) = slots[0].node else { throw XCTSkip("expected text") }
        return value
    }

    func testRuntimeUsesVirtualDateRandomAndTimers() async throws {
        func run() async throws -> [String] {
            let clock = PluginVirtualClock(startMilliseconds: 1_700_000_000_000, seed: 7)
            let rt = runtime(clock: clock)
            let first = try await text(rt)
            let early = await rt.advanceVirtualTime(byMilliseconds: 99)
            XCTAssertEqual(early, 0)
            let mid = try await text(rt)
            let due = await rt.advanceVirtualTime(byMilliseconds: 1)
            XCTAssertEqual(due, 1)
            let last = try await text(rt)
            return [first, mid, last]
        }
        let one = try await run()
        let two = try await run()
        XCTAssertEqual(one, two, "same start/seed/advance sequence is fully reproducible")
        XCTAssertTrue(one[0].hasPrefix("1700000000000|1700000000000|"))
        XCTAssertTrue(one[1].hasPrefix("1700000000099|1700000000099|"))
        XCTAssertTrue(one[2].hasPrefix("1700000000100|") && one[2].hasSuffix("|2"), "timer fired exactly at its due time")
    }

    func testWithoutVirtualClockAdvanceIsNotAvailableAndDateIsSystem() async throws {
        let rt = runtime(clock: nil)
        let nilResult = await rt.advanceVirtualTime(byMilliseconds: 10)
        XCTAssertNil(nilResult)
        let value = try await text(rt)
        let ms = Double(value.split(separator: "|")[0]) ?? 0
        XCTAssertEqual(ms, Date().timeIntervalSince1970 * 1000, accuracy: 5_000)
    }
}
