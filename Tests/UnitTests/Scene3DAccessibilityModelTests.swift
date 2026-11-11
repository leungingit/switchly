import XCTest
@testable import Switchly

final class Scene3DAccessibilityModelTests: XCTestCase {
    func testTextHitsAndResetAreIndependentElements() {
        let elements = Scene3DAccessibilityModel.elements(
            texts: [.init(id: "title", label: "Song", value: "Blue Monday")],
            hits: [
                .init(node: "play", actionID: "toggle", label: "Pause", value: 0),
                .init(node: "love", actionID: "love", label: "Like", isToggle: true, selected: true),
            ],
            resetViewLabel: "Reset view"
        )

        XCTAssertEqual(elements.map(\.role), [.text, .button, .toggle, .reset])
        XCTAssertEqual(elements.first?.value, "Blue Monday")
        XCTAssertNil(elements.first?.actionID)
        XCTAssertEqual(elements[1].actionID, "toggle")
        XCTAssertEqual(elements[2].isSelected, true)
        XCTAssertEqual(elements[2].actionID, "love")
        XCTAssertEqual(elements.last?.id, Scene3DAccessibilityModel.resetViewElementID)
        XCTAssertEqual(elements.last?.actionID, Scene3DAccessibilityModel.resetViewElementID)
    }

    func testDisabledToggleHasNoActionButKeepsState() {
        let elements = Scene3DAccessibilityModel.elements(
            texts: [],
            hits: [.init(node: "love", actionID: "love", label: "Like",
                         enabled: false, isToggle: true, selected: false)],
            resetViewLabel: "Reset view"
        )
        let toggle = elements.first { $0.role == .toggle }
        XCTAssertEqual(toggle?.isEnabled, false)
        XCTAssertNil(toggle?.actionID)
        XCTAssertEqual(toggle?.isSelected, false)
    }

    func testDuplicateElementIDsAreDropped() {
        let elements = Scene3DAccessibilityModel.elements(
            texts: [
                .init(id: "title", label: "Title", value: "A"),
                .init(id: "title", label: "Title", value: "B"),
            ],
            hits: [
                .init(node: "play", actionID: "toggle", label: "Play"),
                .init(node: "play2", actionID: "toggle", label: "Play again"),
            ],
            resetViewLabel: "Reset view"
        )
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements.first?.value, "A")
    }

    func testResetElementCannotBeOverriddenByTextID() {
        let elements = Scene3DAccessibilityModel.elements(
            texts: [.init(id: Scene3DAccessibilityModel.resetViewElementID, label: "Text", value: "")],
            hits: [],
            resetViewLabel: "Reset view"
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.role, .text)
    }
}
