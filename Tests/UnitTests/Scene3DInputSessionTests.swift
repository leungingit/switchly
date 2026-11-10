import XCTest
import simd
@testable import Switchly

@MainActor
private final class RecordingHitProvider: Scene3DHitProviding {
    var candidates: [Scene3DHitRouter.Candidate] = []
    private(set) var queriedPoints: [CGPoint] = []

    func hitCandidates(at point: CGPoint) -> [Scene3DHitRouter.Candidate] {
        queriedPoints.append(point)
        return candidates
    }
}

@MainActor
final class Scene3DInputSessionTests: XCTestCase {
    private var actions: [String] = []
    private var values: [Double?] = []
    private var cameraChanges: [Scene3DCameraController.Pose] = []
    private var provider: RecordingHitProvider!
    private var session: Scene3DInputSession!

    override func setUp() {
        super.setUp()
        actions = []
        values = []
        cameraChanges = []
        provider = RecordingHitProvider()
        session = Scene3DInputSession(
            hitProvider: provider,
            hits: [
                .init(node: "play", actionID: "toggle", label: "Play", value: 0),
                .init(node: "love", actionID: "love", label: "Love", enabled: false),
            ],
            reduceMotion: { false },
            actionSink: { [unowned self] id, value in
                self.actions.append(id)
                self.values.append(value)
            }
        )
        session.onCameraChanged = { [unowned self] pose in
            self.cameraChanges.append(pose)
        }
    }

    override func tearDown() {
        session = nil
        provider = nil
        super.tearDown()
    }

    func testClickDispatchesOnceAtDownPoint() {
        provider.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        session.start()
        session.pointerDown(at: CGPoint(x: 12, y: 8))
        session.pointerUp(at: CGPoint(x: 12, y: 8))

        XCTAssertEqual(actions, ["toggle"])
        XCTAssertEqual(values, [0.0])
        XCTAssertEqual(provider.queriedPoints, [CGPoint(x: 12, y: 8)])
        XCTAssertEqual(session.cameraPose, .init())
    }

    func testSubThresholdMoveStillClicksWithoutRotating() {
        provider.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        session.start()
        session.pointerDown(at: .zero)
        session.pointerDragged(to: CGPoint(x: 2, y: 0))
        session.pointerUp(at: CGPoint(x: 2, y: 0))

        XCTAssertEqual(actions, ["toggle"])
        XCTAssertEqual(session.cameraPose, .init())
    }

    func testDragRotatesAndDispatchesNoAction() {
        provider.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        session.start()
        session.pointerDown(at: .zero)
        session.pointerDragged(to: CGPoint(x: 20, y: 10))
        session.pointerUp(at: CGPoint(x: 20, y: 10))

        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(provider.queriedPoints.isEmpty)
        XCTAssertEqual(session.cameraPose.yaw, 8, accuracy: 1e-9)  // 20 pt × 0.4°/pt
        XCTAssertEqual(session.cameraPose.pitch, -4, accuracy: 1e-9)
        XCTAssertFalse(session.isCameraSettled)
    }

    func testReduceMotionStopsInertiaAfterDrag() {
        let reduced = Scene3DInputSession(
            hitProvider: provider,
            hits: [],
            reduceMotion: { true },
            actionSink: { _, _ in }
        )
        reduced.start()
        reduced.pointerDown(at: .zero)
        reduced.pointerDragged(to: CGPoint(x: 20, y: 0))
        reduced.pointerUp(at: CGPoint(x: 20, y: 0))

        XCTAssertTrue(reduced.isCameraSettled)
        XCTAssertFalse(reduced.advance(by: 0.016))
    }

    func testBackFaceClickDoesNotDispatch() {
        provider.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, -1), worldPoint: .zero),
        ]
        session.start()
        session.pointerDown(at: .zero)
        session.pointerUp(at: .zero)

        XCTAssertTrue(actions.isEmpty)
    }

    func testDisabledHitClickDoesNotDispatch() {
        provider.candidates = [
            .init(nodeNameChain: ["love"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        session.start()
        session.pointerDown(at: .zero)
        session.pointerUp(at: .zero)

        XCTAssertTrue(actions.isEmpty)
    }

    func testStopStopsPointerInertiaAndAccessibilityCallbacks() {
        provider.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        session.start()
        session.pointerDown(at: .zero)
        session.pointerUp(at: .zero)
        XCTAssertEqual(actions, ["toggle"])

        session.pointerDown(at: .zero)
        session.pointerDragged(to: CGPoint(x: 20, y: 0))
        session.pointerUp(at: CGPoint(x: 20, y: 0))
        let changesBeforeStop = cameraChanges.count

        session.stop()
        session.pointerDown(at: .zero)
        session.pointerUp(at: .zero)
        session.pointerDragged(to: CGPoint(x: 20, y: 0))
        XCTAssertFalse(session.advance(by: 0.016))
        XCTAssertFalse(session.resetView())
        XCTAssertFalse(session.performAccessibilityAction("toggle"))
        XCTAssertFalse(session.performAccessibilityAction(Scene3DAccessibilityModel.resetViewElementID))

        XCTAssertEqual(actions, ["toggle"])
        XCTAssertEqual(cameraChanges.count, changesBeforeStop)
    }

    func testRestartReEnablesInput() {
        provider.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        session.start()
        session.stop()
        session.start()
        session.pointerDown(at: .zero)
        session.pointerUp(at: .zero)

        XCTAssertEqual(actions, ["toggle"])
    }

    func testAccessibilityActionUsesHitValueAndReset() {
        session.start()
        session.pointerDown(at: .zero)
        session.pointerDragged(to: CGPoint(x: 20, y: 0))
        session.pointerUp(at: CGPoint(x: 20, y: 0))

        XCTAssertTrue(session.performAccessibilityAction("toggle"))
        XCTAssertEqual(actions, ["toggle"])
        XCTAssertEqual(values, [0.0])
        XCTAssertFalse(session.performAccessibilityAction("love"))

        XCTAssertTrue(session.resetView())
        XCTAssertEqual(session.cameraPose, .init())
    }

    func testInertiaFramesStopAfterStop() {
        session.start()
        session.pointerDown(at: .zero)
        session.pointerDragged(to: CGPoint(x: 20, y: 0))
        session.pointerUp(at: CGPoint(x: 20, y: 0))
        XCTAssertTrue(session.advance(by: 0.016))
        let changes = cameraChanges.count

        session.stop()
        XCTAssertFalse(session.advance(by: 0.016))
        XCTAssertEqual(cameraChanges.count, changes)
    }

    func testSessionDoesNotRetainItsHitProvider() {
        var provider: RecordingHitProvider? = RecordingHitProvider()
        weak var weakProvider = provider
        provider?.candidates = [
            .init(nodeNameChain: ["play"], worldNormal: SIMD3(0, 0, 1), worldPoint: .zero),
        ]
        var dispatched: [String] = []
        let session = Scene3DInputSession(
            hitProvider: provider!,
            hits: [.init(node: "play", actionID: "toggle", label: "Play", value: 0)],
            reduceMotion: { false },
            actionSink: { id, _ in dispatched.append(id) }
        )
        session.start()

        provider = nil
        XCTAssertNil(weakProvider, "the session must not keep the host controller alive")

        // A click whose provider is already gone must be ignored, not crash.
        session.pointerDown(at: .zero)
        session.pointerUp(at: .zero)
        XCTAssertTrue(dispatched.isEmpty)
    }

    func testSpinStartsAnimatedTurnAndEmitsPoseChanges() {
        session.start()
        XCTAssertTrue(session.spin(.right))
        XCTAssertFalse(session.isCameraSettled)
        XCTAssertTrue(session.advance(by: 0.2))
        XCTAssertFalse(cameraChanges.isEmpty)
    }

    func testSpinIsIgnoredBeforeStartAndAfterStop() {
        XCTAssertFalse(session.spin(.left))
        session.start()
        session.stop()
        XCTAssertFalse(session.spin(.left))
        XCTAssertTrue(session.isCameraSettled)
    }

    func testPointerDownCancelsRunningSpin() {
        session.start()
        session.spin(.right)
        session.pointerDown(at: .zero)
        XCTAssertTrue(session.isCameraSettled)
    }

    func testSpinUnderReduceMotionTurnsInstantlyInsteadOfAnimating() {
        let reduced = Scene3DInputSession(hitProvider: provider, hits: [],
                                          reduceMotion: { true }, actionSink: { _, _ in })
        reduced.onCameraChanged = { [unowned self] in self.cameraChanges.append($0) }
        reduced.start()
        XCTAssertTrue(reduced.spin(.right))
        XCTAssertTrue(reduced.isCameraSettled)
        XCTAssertEqual(reduced.cameraPose.yaw, 90)
        XCTAssertEqual(cameraChanges.last?.yaw, 90)
    }
}
