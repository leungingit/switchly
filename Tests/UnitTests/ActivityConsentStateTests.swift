import XCTest
@testable import Switchly

final class ActivityConsentStateTests: XCTestCase {
    func testOnlyOneConfirmationCanBePresented() throws {
        var state = ActivityConsentState()
        state.present(.clear)
        let current = try XCTUnwrap(state.request)
        state.present(.recording)
        XCTAssertEqual(state.request, current)
        XCTAssertNil(state.consume(current))
        XCTAssertEqual(state.request, current)
    }
    func testStaleAllowCannotConsumeClearConfirmation() throws {
        var state = ActivityConsentState()
        state.present(.recording)
        let oldAllow = try XCTUnwrap(state.request)
        state.cancel()
        state.present(.clear)
        let currentClear = try XCTUnwrap(state.request)
        state.clearText = ActivityConsentState.requiredClearText
        XCTAssertNil(state.consume(oldAllow))
        XCTAssertEqual(state.request, currentClear)
        XCTAssertEqual(state.consume(currentClear), .clear)
    }
    func testClearRequiresExactConfirmationWord() throws {
        var state = ActivityConsentState()
        state.present(.clear)
        let request = try XCTUnwrap(state.request)
        for text in ["", "clear", "CLEAR ", " CLEAR", "Allow"] {
            state.clearText = text
            XCTAssertFalse(state.canClear)
            XCTAssertNil(state.consume(request))
        }
        state.clearText = ActivityConsentState.requiredClearText
        XCTAssertTrue(state.canClear)
        XCTAssertEqual(state.consume(request), .clear)
        XCTAssertNil(state.request)
        XCTAssertEqual(state.clearText, "")
    }
    func testCancelledClearCannotAuthorizeReopenedConfirmation() throws {
        var state = ActivityConsentState()
        state.present(.clear)
        let old = try XCTUnwrap(state.request)
        state.clearText = ActivityConsentState.requiredClearText
        state.cancel()
        state.present(.clear)
        let current = try XCTUnwrap(state.request)
        XCTAssertNotEqual(current.id, old.id)
        XCTAssertEqual(state.clearText, "")
        XCTAssertNil(state.consume(old))
        XCTAssertNil(state.consume(current))
    }
    func testStaleClearCannotConsumeNewlyTypedRequest() throws {
        var state = ActivityConsentState()
        state.present(.clear)
        let old = try XCTUnwrap(state.request)
        state.cancel()
        state.present(.clear)
        let current = try XCTUnwrap(state.request)
        state.clearText = ActivityConsentState.requiredClearText
        XCTAssertNil(state.consume(old))
        XCTAssertEqual(state.request, current)
        XCTAssertEqual(state.consume(current), .clear)
    }
    func testAllowOnlyConsumesItsOwnIntentAndResetsState() throws {
        var state = ActivityConsentState()
        state.present(.screenshots)
        let request = try XCTUnwrap(state.request)
        XCTAssertFalse(state.canClear)
        XCTAssertEqual(state.consume(request), .screenshots)
        XCTAssertNil(state.consume(request))
        XCTAssertNil(state.request)
        XCTAssertEqual(state.clearText, "")
    }
}
