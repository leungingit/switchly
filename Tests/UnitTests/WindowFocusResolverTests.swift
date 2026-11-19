import AppKit
import XCTest
@testable import Switchly

final class WindowFocusResolverTests: XCTestCase {
    func testEnumerationFailureKeepsBothAXResultsWithoutTryingAnyWindow() throws {
        let fixture = Fixture([.failed(.apiDisabled), .failed(.cannotComplete)])
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window()))

        XCTAssertEqual(failure.stage, .axEnumerationFailed)
        XCTAssertEqual(failure.logFields, "stage=axEnumerationFailed, initialAX=error:-25211, fallbackAX=error:-25204, remoteLookup=notRun, focusAttempts=0")
        XCTAssertEqual(fixture.events, ["enumerate", "enumerate", "grace"])
    }

    func testSuccessfulEmptyFallbackIsDistinctFromEnumerationFailure() throws {
        let fixture = Fixture([.invalidResponse, .windows([])])
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window()))

        XCTAssertEqual(failure.stage, .targetNotFound)
        XCTAssertEqual(failure.initialAX, "invalidResponse")
        XCTAssertEqual(failure.fallbackAX, "windows:0")
        XCTAssertEqual(failure.focusAttempts, 0)
    }

    func testCrossSpaceLookupMissNeverRaisesAnUnrelatedEnumeratedWindow() throws {
        let unrelated = AXUIElementCreateApplication(111)
        let fixture = Fixture([.windows([unrelated])])
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window(otherSpace: true)))

        XCTAssertEqual(failure.stage, .otherSpaceTargetNotFound)
        XCTAssertEqual(failure.initialAX, "windows:1")
        XCTAssertEqual(failure.fallbackAX, "notRun")
        XCTAssertEqual(failure.remoteLookup, .miss)
        XCTAssertEqual(fixture.events, ["enumerate", "remote"])
    }

    func testCrossSpaceLookupMissPreservesAnEnumerationError() throws {
        let fixture = Fixture([.failed(.apiDisabled)])
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window(otherSpace: true)))

        XCTAssertEqual(failure.stage, .axEnumerationFailed)
        XCTAssertEqual(failure.initialAX, "error:-25211")
        XCTAssertEqual(failure.remoteLookup, .miss)
        XCTAssertEqual(fixture.events, ["enumerate", "remote"])
    }

    func testCrossSpaceFrontRequestFailureDoesNotClaimVerificationRan() throws {
        let fixture = Fixture([.windows([])])
        fixture.remoteElement = AXUIElementCreateApplication(111)
        fixture.frontResults = [false]
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window(otherSpace: true)))

        XCTAssertEqual(failure.stage, .frontRequestFailed)
        XCTAssertEqual(failure.remoteLookup, .hit)
        XCTAssertEqual(failure.focusAttempts, 0)
        XCTAssertEqual(fixture.events, ["enumerate", "remote", "front"])
    }

    func testVerificationFailurePreservesErrorFromFallbackEnumeration() throws {
        let exact = AXUIElementCreateApplication(111)
        let fixture = Fixture([.windows([exact]), .failed(.apiDisabled)])
        fixture.exactElement = exact
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window()))

        XCTAssertEqual(failure.stage, .focusVerificationFailed)
        XCTAssertEqual(failure.initialAX, "windows:1")
        XCTAssertEqual(failure.fallbackAX, "error:-25211")
        XCTAssertEqual(failure.focusAttempts, 1)
        XCTAssertEqual(fixture.events, ["enumerate", "activate", "focus:exact", "enumerate", "grace"])
    }

    func testCrossSpaceVerificationRetriesOnlyTheExactWindow() throws {
        let exact = AXUIElementCreateApplication(111)
        let fixture = Fixture([.windows([exact])])
        fixture.exactElement = exact
        fixture.frontResults = [true, false, true]
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window(otherSpace: true)))

        XCTAssertEqual(failure.stage, .focusVerificationFailed)
        XCTAssertEqual(failure.remoteLookup, .notRun)
        XCTAssertEqual(failure.focusAttempts, 2)
        XCTAssertEqual(fixture.focusedElements.count, 2)
        XCTAssertTrue(fixture.focusedElements.allSatisfy { CFEqual($0, exact) })
        XCTAssertEqual(fixture.events, [
            "enumerate", "front", "focus:exactOtherSpace", "grace", "front", "grace",
            "activate", "front", "focus:exactOtherSpaceActivated", "grace", "forget"
        ])
    }

    func testRemoteRecoveryAfterEnumerationErrorDoesNotProduceFailure() {
        let fixture = Fixture([.failed(.apiDisabled)])
        fixture.remoteElement = AXUIElementCreateApplication(111)
        fixture.focusSucceeds = true

        XCTAssertNil(fixture.resolver.resolveAndFocus(window(otherSpace: true)))
        XCTAssertEqual(fixture.events, ["enumerate", "remote", "front", "focus:exactOtherSpace"])
    }

    func testGraceSuccessAfterEnumerationFailureDoesNotProduceFailure() {
        let fixture = Fixture([.failed(.apiDisabled), .failed(.apiDisabled)])
        fixture.graceSucceeds = true

        XCTAssertNil(fixture.resolver.resolveAndFocus(window()))
        XCTAssertEqual(fixture.events, ["enumerate", "enumerate", "grace"])
    }

    func testFallbackProbesOnlyNewElementsAndStopsOnVerifiedSuccess() {
        let tried = AXUIElementCreateApplication(111)
        let replacement = AXUIElementCreateApplication(112)
        let fixture = Fixture([.windows([tried]), .windows([tried, replacement])])
        fixture.exactElement = tried
        fixture.focusResults = [false, true]

        XCTAssertNil(fixture.resolver.resolveAndFocus(window()))
        XCTAssertEqual(fixture.focusedElements.count, 2)
        XCTAssertTrue(fixture.focusedElements.last.map { CFEqual($0, replacement) } ?? false)
        XCTAssertEqual(fixture.events, ["enumerate", "activate", "focus:exact", "enumerate", "activate", "focus:probe"])
    }

    func testCandidateAndFallbackShareTheExistingAttemptLimit() throws {
        let elements = (111...117).map { AXUIElementCreateApplication(pid_t($0)) }
        let fixture = Fixture([.windows(elements), .windows(elements)])
        fixture.exactElement = elements[0]
        let failure = try XCTUnwrap(fixture.resolver.resolveAndFocus(window()))

        XCTAssertEqual(failure.stage, .focusVerificationFailed)
        XCTAssertEqual(failure.focusAttempts, 5)
        XCTAssertEqual(fixture.focusedElements.count, 5)
        XCTAssertEqual(fixture.events.last, "grace")
    }

    private func window(otherSpace: Bool = false) -> WindowInfo {
        WindowInfo(id: 55, ownerPID: 110, ownerName: "Fixture", windowTitle: "", bounds: .zero,
                   isOnCurrentSpace: !otherSpace, windowNumber: 55, isOnOtherSpace: otherSpace)
    }

    private final class Fixture {
        var enumerations: [AXWindowEnumeration]
        var exactElement: AXUIElement?
        var remoteElement: AXUIElement?
        var frontResults: [Bool] = []
        var focusResults: [Bool] = []
        var focusSucceeds = false
        var graceSucceeds = false
        var events: [String] = []
        var focusedElements: [AXUIElement] = []

        init(_ enumerations: [AXWindowEnumeration]) {
            self.enumerations = enumerations
        }

        var resolver: WindowFocusResolver {
            WindowFocusResolver(
                enumerate: { _ in
                    self.events.append("enumerate")
                    return self.enumerations.isEmpty ? .invalidResponse : self.enumerations.removeFirst()
                },
                candidates: { _, windows in
                    guard let exact = self.exactElement, windows.contains(where: { CFEqual($0, exact) }) else { return [] }
                    return [WindowFocusCandidate(element: exact, reason: "exact", needsUnminimize: false)]
                },
                remoteWindow: { _ in
                    self.events.append("remote")
                    return self.remoteElement
                },
                requestFront: { _ in
                    self.events.append("front")
                    return self.frontResults.isEmpty ? true : self.frontResults.removeFirst()
                },
                forgetRemoteWindow: { _ in self.events.append("forget") },
                ensureFrontmost: { _ in self.events.append("activate") },
                focus: { candidate, _ in
                    self.events.append("focus:\(candidate.reason)")
                    self.focusedElements.append(candidate.element)
                    return self.focusResults.isEmpty ? self.focusSucceeds : self.focusResults.removeFirst()
                },
                awaitLateFront: { _ in
                    self.events.append("grace")
                    return self.graceSucceeds
                }
            )
        }
    }
}
