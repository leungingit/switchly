import XCTest
import SceneKit
@testable import Switchly

@MainActor
final class Scene3DHitTestAdapterTests: XCTestCase {
    func testNameChainWalksAncestorsNearestFirstAndSkipsEmptyNames() {
        let root = SCNNode()
        root.name = "asset_root"
        let middle = SCNNode()
        middle.name = nil
        let leaf = SCNNode()
        leaf.name = "wheel_play"
        root.addChildNode(middle)
        middle.addChildNode(leaf)

        XCTAssertEqual(Scene3DHitTestAdapter.nameChain(from: leaf),
                       ["wheel_play", "asset_root"])
        XCTAssertEqual(Scene3DHitTestAdapter.nameChain(from: nil), [])
    }

    func testEmptyViewReturnsNoCandidates() {
        let adapter = Scene3DHitTestAdapter(view: nil)
        XCTAssertTrue(adapter.hitCandidates(at: .zero).isEmpty)
    }
}
