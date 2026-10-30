import XCTest
@testable import Switchly

final class AppActivationTrackerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func tracker(frontmost: String?) -> AppActivationTracker {
        AppActivationTracker(center: NotificationCenter(), frontmost: frontmost, now: { [unowned self] in self.clock })
    }

    func testAnAppInFrontIsActiveNowAndRemembersWhenItLeft() {
        let t = tracker(frontmost: "a")
        clock = Date(timeIntervalSince1970: 1_050)
        XCTAssertEqual(t.lastActiveAt(bundleID: "a"), clock)
        XCTAssertNil(t.lastActiveAt(bundleID: "b"), "never seen")
        t.activated(bundleID: "b")
        XCTAssertEqual(t.lastActiveAt(bundleID: "a"), Date(timeIntervalSince1970: 1_050))
        clock = Date(timeIntervalSince1970: 1_200)
        XCTAssertEqual(t.lastActiveAt(bundleID: "a"), Date(timeIntervalSince1970: 1_050), "time stops once it left")
        XCTAssertEqual(t.lastActiveAt(bundleID: "b"), clock)
    }

    func testActivatingTheSameAppAgainChangesNothing() {
        let t = tracker(frontmost: "a")
        t.activated(bundleID: "a")
        XCTAssertNil(t.lastActiveAt(bundleID: "z"))
        XCTAssertEqual(t.lastActiveAt(bundleID: "a"), clock)
    }
}
