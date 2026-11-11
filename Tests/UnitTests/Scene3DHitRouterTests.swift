import XCTest
import simd
@testable import Switchly

final class Scene3DHitRouterTests: XCTestCase {
    private let frontCamera = SIMD3<Float>(0, 0, 4)

    private func candidate(names: [String],
                           normal: SIMD3<Float> = SIMD3(0, 0, 1),
                           point: SIMD3<Float> = .zero,
                           passesThrough: Bool = false,
                           local: SIMD2<Float>? = nil) -> Scene3DHitRouter.Candidate {
        Scene3DHitRouter.Candidate(nodeNameChain: names, worldNormal: normal, worldPoint: point,
                                   passesThrough: passesThrough, localPoint: local)
    }

    func testUndeclaredOpaqueSurfaceBlocksDeclaredHitBehind() {
        let router = Scene3DHitRouter(hits: [.init(node: "btn", actionID: "toggle", label: "Play")])
        let routed = router.route(candidates: [candidate(names: ["body"]), candidate(names: ["btn"])],
                                  cameraPosition: frontCamera)
        XCTAssertNil(routed)
    }

    func testTransparentPlaceholderPassesThroughToDeclaredHit() {
        let router = Scene3DHitRouter(hits: [.init(node: "btn", actionID: "toggle", label: "Play")])
        let routed = router.route(candidates: [candidate(names: ["ghost"], passesThrough: true),
                                               candidate(names: ["btn"])],
                                  cameraPosition: frontCamera)
        XCTAssertEqual(routed?.id, "toggle")
    }

    func testFrontHitMapsNodeNameToAction() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "mesh_wheel_play", actionID: "toggle", label: "Play", value: 1),
        ])
        let routed = router.route(candidates: [candidate(names: ["mesh_wheel_play"])],
                                  cameraPosition: frontCamera)
        XCTAssertEqual(routed, .init(id: "toggle", value: 1))
    }

    func testHitMatchesAncestorNodeName() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "controls", actionID: "toggle", label: "Play"),
        ])
        let routed = router.route(candidates: [candidate(names: ["wheel_mesh", "controls"])],
                                  cameraPosition: frontCamera)
        XCTAssertEqual(routed?.id, "toggle")
    }

    func testBackFaceDoesNotTriggerFrontAction() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "front_panel", actionID: "toggle", label: "Play"),
        ])
        // Same node name, but the outward normal points away from the camera.
        let routed = router.route(candidates: [candidate(names: ["front_panel"], normal: SIMD3(0, 0, -1))],
                                  cameraPosition: frontCamera)
        XCTAssertNil(routed)
    }

    func testSideFaceBelowThresholdIsRejected() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "side", actionID: "next", label: "Next"),
        ])
        // Normal mostly +X while the camera is on +Z: grazing, not front-facing.
        let routed = router.route(candidates: [candidate(names: ["side"], normal: SIMD3(1, 0, 0.01))],
                                  cameraPosition: frontCamera)
        XCTAssertNil(routed)
    }

    func testNearestVisibleHitWins() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "back_wheel", actionID: "previous", label: "Previous"),
            .init(node: "front_wheel", actionID: "next", label: "Next"),
        ])
        let routed = router.route(
            candidates: [candidate(names: ["back_wheel"], normal: SIMD3(0, 0, 1))],
            cameraPosition: frontCamera
        )
        XCTAssertEqual(routed?.id, "previous")
    }

    func testDisabledNearestHitBlocksFallThrough() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "back_wheel", actionID: "like", label: "Like", enabled: false),
            .init(node: "front_wheel", actionID: "next", label: "Next"),
        ])
        let routed = router.route(
            candidates: [
                candidate(names: ["back_wheel"]),
                candidate(names: ["front_wheel"]),
            ],
            cameraPosition: frontCamera
        )
        XCTAssertNil(routed)
    }

    func testUndeclaredMeshDoesNotRoute() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "screen", actionID: "screen", label: "Screen"),
        ])
        let routed = router.route(candidates: [candidate(names: ["case"])],
                                  cameraPosition: frontCamera)
        XCTAssertNil(routed)
    }

    func testLookupByActionIDRespectsEnabled() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "love", actionID: "love", label: "Love", enabled: false),
        ])
        XCTAssertEqual(router.hit(actionID: "love")?.enabled, false)
        XCTAssertNil(router.hit(actionID: "missing"))
    }

    func testSectorHitsOnOneNodeRouteByLocalPoint() {
        let router = Scene3DHitRouter(hits: [
            .init(node: "ring", actionID: "up", label: "Up", sector: .top),
            .init(node: "ring", actionID: "left", label: "Left", sector: .left),
            .init(node: "ring", actionID: "right", label: "Right", sector: .right),
            .init(node: "ring", actionID: "down", label: "Down", sector: .bottom),
        ])
        func route(_ x: Float, _ y: Float) -> String? {
            router.route(candidates: [candidate(names: ["ring"], local: SIMD2(x, y))],
                         cameraPosition: frontCamera)?.id
        }
        XCTAssertEqual(route(0, 60), "up")
        XCTAssertEqual(route(-60, 10), "left")
        XCTAssertEqual(route(60, -10), "right")
        XCTAssertEqual(route(5, -60), "down")
        // 没有局部坐标时无法判定扇区，不派发。
        XCTAssertNil(router.route(candidates: [candidate(names: ["ring"])], cameraPosition: frontCamera))
    }
}
