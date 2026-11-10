//
//  PluginScene3DControllerTests.swift
//  SwitchlyTests
//
//  T06: lifecycle tests for the generic scene3d controller. Every dependency
//  (loader, cache, host, frame scheduler, rasterizer) is injected so the tests
//  stay deterministic and never decode a real GLB or touch the GPU.
//
//  Covered here:
//  - async load success/failure and asset-missing fallback;
//  - stale generation, cancellation and configure switches;
//  - idempotent start/stop, unload and teardown;
//  - the 220×380 pt slot policy and resize reassembly;
//  - pointer hit routing, inertia framing, Reduce Motion and reset;
//  - accessibility elements/actions and two-instance isolation.
//

import AppKit
import CoreGraphics
import SceneKit
import XCTest
@testable import Switchly

@MainActor
final class PluginScene3DControllerTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/switchly-scene3d-controller-tests")
    private let slot = CGSize(width: 320, height: 420)

    // MARK: - Load success

    func testLoadsSceneMountsHostAndExposesAccessibility() async throws {
        let host = Scene3DFakeHost()
        let (controller, _) = makeController(loader: Scene3DTestLoader(template: makeTemplate()))
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)

        let instance = try XCTUnwrap(controller.instance)
        XCTAssertEqual(controller.state, .ready(instance.identity))
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(controller.hitSession?.isActive == true)
        XCTAssertTrue(host.mounted.compactMap { $0 }.contains { $0 === instance.scene })
        XCTAssertGreaterThan(host.refreshCount, 0)
        XCTAssertEqual(controller.accessibilityElements.map(\.id),
                       ["hit.press", Scene3DAccessibilityModel.resetViewElementID])
        XCTAssertEqual(controller.accessibilityElements.first?.actionID, "press")
        XCTAssertEqual(instance.surfaceTextureCount, 0)
    }

    func testClickGivesVisiblePressFeedbackAndRespectsReduceMotion() async throws {
        for reduce in [false, true] {
            let host = Scene3DFakeHost()
            host.candidates = [Scene3DHitRouter.Candidate(
                nodeNameChain: ["button"], worldNormal: SIMD3<Float>(0, 0, 1),
                worldPoint: SIMD3<Float>(0, 0, 0))]
            let (controller, _) = makeController(loader: Scene3DTestLoader(template: makeTemplate()),
                                                 reduceMotion: { reduce })
            controller.updateSlotSize(slot)
            controller.attach(host: host)
            controller.start()
            await waitForReady(controller)
            let node = try XCTUnwrap(controller.instance?.contentRoot.childNode(withName: "button", recursively: true))
            controller.pointerDown(at: CGPoint(x: 10, y: 10))
            controller.pointerUp(at: CGPoint(x: 10, y: 10))
            XCTAssertEqual(node.actionKeys.contains("scene3d.press"), !reduce)
            controller.stop()
        }
    }

    func testDescriptorCameraBecomesTheInitialPose() async throws {
        var descriptor = baseDescriptor()
        descriptor.camera = PluginScene3DCamera(yaw: 15, pitch: -5)
        let (controller, _) = makeController(loader: Scene3DTestLoader(template: makeTemplate()),
                                             descriptor: descriptor)
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)

        XCTAssertEqual(controller.cameraPose, Scene3DCameraController.Pose(yaw: 15, pitch: -5))
        let instance = try XCTUnwrap(controller.instance)
        let expected = Scene3DCameraController.Geometry.worldPosition(for: controller.cameraPose)
        XCTAssertEqual(instance.cameraNode.position.x, CGFloat(expected.x), accuracy: 0.0001)
        XCTAssertEqual(instance.cameraNode.position.z, CGFloat(expected.z), accuracy: 0.0001)
    }

    // MARK: - Load failures

    func testPreflightFailureFallsBackAndTearsDown() async throws {
        let host = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate(),
                                       outcome: .failure(.preflightRejected("too big")))
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForFallback(controller)

        XCTAssertEqual(controller.state, .fallback(.preflightRejected("too big")))
        XCTAssertNil(controller.instance)
        XCTAssertTrue(controller.accessibilityElements.isEmpty)
        XCTAssertTrue(controller.hitSession == nil)
        XCTAssertNil(host.mounted.last ?? nil)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testAssetMissingWhenReaderThrows() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader, dataReader: { _ in throw CocoaError(.fileReadNoSuchFile) })
        controller.updateSlotSize(slot)
        controller.start()
        await waitForFallback(controller)

        XCTAssertEqual(controller.state, .fallback(.assetMissing))
        XCTAssertEqual(loader.callCount, 0)
    }

    func testAssemblyFailureFallsBackToDecodeFailed() async throws {
        // An empty template survives load and preflight but cannot be framed.
        let loader = Scene3DTestLoader(template: SCNScene())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.start()
        await waitForFallback(controller)

        guard case .fallback(.decodeFailed) = controller.state else {
            return XCTFail("expected decodeFailed, got \(controller.state)")
        }
        XCTAssertNil(controller.instance)
    }

    func testRealFailureIsNotRetriedByResize() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate(),
                                       outcome: .failure(.preflightRejected("bad")))
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.start()
        await waitForFallback(controller)

        controller.updateSlotSize(CGSize(width: 340, height: 400))
        XCTAssertEqual(controller.state, .fallback(.preflightRejected("bad")))
        XCTAssertEqual(loader.callCount, 1)
    }

    // MARK: - Generation and cancellation

    func testStaleLoadCannotOverrideANewConfiguration() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate(), gateFirstCall: true)
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.start()
        await waitFor(controller, "first loader call") { loader.callCount == 1 }
        XCTAssertEqual(controller.state, .loading)

        controller.configure(
            descriptor: baseDescriptor(key: "other"),
            pluginID: "other.plugin",
            assetDirectory: directory,
            artwork: nil,
            palette: .system()
        )
        await waitForReady(controller)
        let current = try XCTUnwrap(controller.instance)
        XCTAssertEqual(current.identity.pluginID, "other.plugin")
        XCTAssertEqual(loader.callCount, 2)

        // Release the blocked first load; its result belongs to an old generation.
        loader.releaseFirstCall()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.instance?.identity, current.identity)
        XCTAssertEqual(controller.state, .ready(current.identity))
    }

    func testStopCancelsAPendingLoad() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate(), gateFirstCall: true)
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.start()
        await waitFor(controller, "first loader call") { loader.callCount == 1 }
        XCTAssertEqual(controller.state, .loading)

        controller.stop()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.state, .idle)
        loader.releaseFirstCall()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(controller.instance)
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Idempotent lifecycle

    func testRepeatedStartAndStopAreIdempotent() async throws {
        let host = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, scheduler) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)
        let mountsAfterLoad = host.mounted.count

        controller.start()
        XCTAssertEqual(controller.state, .ready(instance.identity))
        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(host.mounted.count, mountsAfterLoad + 1)
        XCTAssertTrue(controller.hitSession?.isActive == true)

        controller.stop()
        controller.stop()
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(controller.instance === instance)
        XCTAssertEqual(controller.state, .ready(instance.identity))
        XCTAssertFalse(controller.hitSession?.isActive == true)
        XCTAssertFalse(scheduler.isRunning)

        // A quick re-show reuses the decoded scene instead of decoding again.
        controller.start()
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(controller.hitSession?.isActive == true)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testUnloadReleasesTexturesAndInstance() async throws {
        let host = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)

        let descriptor = descriptorWithSurface(content: .text(value: "A", style: .body, lines: nil))
        controller.configure(descriptor: descriptor,
                             pluginID: "test.plugin",
                             assetDirectory: directory,
                             artwork: nil,
                             palette: .system())
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)
        XCTAssertEqual(instance.surfaceTextureCount, 1)

        controller.unload()
        XCTAssertNil(controller.instance)
        XCTAssertTrue(instance.isTornDown)
        XCTAssertEqual(instance.surfaceTextureCount, 0)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.accessibilityElements.isEmpty)
        XCTAssertTrue(controller.hitSession == nil)
        XCTAssertNil(host.mounted.last ?? nil)
    }

    func testAttachMountsExistingSceneAndDetachOnlyAcceptsItsHost() async throws {
        let first = Scene3DFakeHost()
        let second = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)

        controller.attach(host: first)
        XCTAssertTrue(first.mounted.compactMap { $0 }.last === instance.scene)
        XCTAssertGreaterThan(first.refreshCount, 0)

        controller.detach(host: second)
        XCTAssertEqual(first.mounted.count, 1, "detaching a foreign host must not clear the attached host")
        controller.detach(host: first)
        XCTAssertNil(first.mounted.last ?? nil)

        // SwiftUI dismantles the old NSView; a new host must mount the scene
        // that is still loaded, and a hide/show cycle remounts it again.
        let replacement = Scene3DFakeHost()
        controller.attach(host: replacement)
        XCTAssertTrue(replacement.mounted.compactMap { $0 }.last === instance.scene)
        controller.stop()
        controller.start()
        XCTAssertTrue(replacement.mounted.compactMap { $0 }.last === instance.scene)
    }

    func testReplacingTheHostUnmountsThePreviousHost() async throws {
        let first = Scene3DFakeHost()
        let second = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.attach(host: first)
        controller.start()
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)
        XCTAssertTrue(first.mounted.compactMap { $0 }.last === instance.scene)

        controller.attach(host: second)
        XCTAssertNil(first.mounted.last ?? nil,
                     "the replaced host must drop its scene before the switch completes")
        XCTAssertTrue(second.mounted.compactMap { $0 }.last === instance.scene)

        // A late dismantle of the old NSView must clear only itself.
        controller.detach(host: first)
        XCTAssertNil(first.mounted.last ?? nil)
        XCTAssertTrue(second.mounted.compactMap { $0 }.last === instance.scene)
    }

    func testControllerAndSessionReleaseWithoutUnload() async throws {
        let host = Scene3DFakeHost()
        weak var weakController: PluginScene3DController?
        weak var weakSession: Scene3DInputSession?
        weak var weakInstance: PluginScene3DInstance?

        var controller: PluginScene3DController? =
            makeController(loader: Scene3DTestLoader(template: makeTemplate())).0
        weakController = controller
        controller?.updateSlotSize(slot)
        controller?.attach(host: host)
        controller?.start()
        await waitForReady(try XCTUnwrap(controller))
        weakSession = controller?.hitSession
        weakInstance = controller?.instance
        XCTAssertNotNil(weakSession)
        XCTAssertNotNil(weakInstance)

        // Dropping the last external reference must release the controller,
        // its input session and its instance even without `unload()`.
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertNil(weakSession, "controller → session → hitProvider must not form a cycle")
        XCTAssertNil(weakInstance)
    }

    func testUpdatedActionSinkAppliesToTheInstalledSession() async throws {
        let host = Scene3DFakeHost()
        host.candidates = [Scene3DHitRouter.Candidate(
            nodeNameChain: ["button"],
            worldNormal: SIMD3<Float>(0, 0, 1),
            worldPoint: SIMD3<Float>(0, 0, 0)
        )]
        var first: [String] = []
        var second: [String] = []
        let (controller, _) = makeController(loader: Scene3DTestLoader(template: makeTemplate()),
                                             actionSink: { id, _ in first.append(id) })
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)
        XCTAssertFalse(controller.hitSession == nil)

        controller.updateActionSink { id, _ in second.append(id) }
        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerUp(at: CGPoint(x: 10, y: 10))

        XCTAssertTrue(first.isEmpty, "the stale action closure must no longer run")
        XCTAssertEqual(second, ["press"])
    }

    // MARK: - View configuration

    func testViewConfigurationDetectsEveryControllerInputChange() {
        let base = PluginScene3DViewConfiguration(
            descriptor: baseDescriptor(),
            pluginID: "test.plugin",
            assetDirectory: directory,
            artworkToken: "cover-a",
            palette: .system()
        )
        XCTAssertEqual(base, base)

        var changed = base
        changed.descriptor = baseDescriptor(key: "other")
        XCTAssertNotEqual(base, changed, "a descriptor change must reconfigure")

        changed = base
        changed.pluginID = "other.plugin"
        XCTAssertNotEqual(base, changed, "a plugin id change must reconfigure")

        changed = base
        changed.assetDirectory = URL(fileURLWithPath: "/tmp/other-scene3d-assets")
        XCTAssertNotEqual(base, changed, "an asset directory change must reconfigure")

        changed = base
        changed.artworkToken = "cover-b"
        XCTAssertNotEqual(base, changed, "an artwork change must reconfigure")
        let pixel = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        changed.artwork = PluginSurfaceArtwork(token: "cover-b", image: pixel)
        XCTAssertEqual(changed.artwork?.token, changed.artworkToken,
                       "the new configuration must carry the image used by onChange")

        changed = base
        changed.palette.text = PluginSurfaceColor(red: 1, green: 0, blue: 0)
        XCTAssertNotEqual(base, changed, "a palette change must reconfigure")
    }

    // MARK: - Slot size

    func testSlotTooSmallFallsBackBeforeLoading() {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(CGSize(width: 132, height: 132))
        XCTAssertEqual(controller.state, .fallback(.slotTooSmall))

        controller.start()
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(controller.canHostScene)
        XCTAssertEqual(loader.callCount, 0)
        XCTAssertEqual(controller.state, .fallback(.slotTooSmall))
    }

    func testGrowingTheSlotRecoversFromSlotTooSmall() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(CGSize(width: 132, height: 132))
        controller.start()
        controller.updateSlotSize(slot)
        await waitForReady(controller)

        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(controller.instance?.viewportSize, slot)
        XCTAssertEqual(controller.state, .ready(try XCTUnwrap(controller.instance).identity))
    }

    func testShrinkingTheSlotTearsDownAndRestoresFromCache() async throws {
        let host = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)

        controller.updateSlotSize(CGSize(width: 132, height: 132))
        XCTAssertEqual(controller.state, .fallback(.slotTooSmall))
        XCTAssertNil(controller.instance)
        XCTAssertTrue(instance.isTornDown)
        XCTAssertNil(host.mounted.last ?? nil)

        controller.updateSlotSize(slot)
        await waitForReady(controller)
        XCTAssertEqual(loader.callCount, 1, "restoring the size must reuse the cached template asset")
        XCTAssertNotNil(controller.instance)
    }

    func testResizeReassemblesFromCacheAndPreservesTheCamera() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader, reduceMotion: { true })
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)

        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerDragged(to: CGPoint(x: 30, y: 10))
        controller.pointerUp(at: CGPoint(x: 30, y: 10))
        XCTAssertEqual(controller.cameraPose.yaw, 8, accuracy: 0.0001)
        let old = try XCTUnwrap(controller.instance)

        let larger = CGSize(width: 260, height: 400)
        controller.updateSlotSize(larger)
        let next = try XCTUnwrap(controller.instance)
        XCTAssertFalse(next === old)
        XCTAssertTrue(old.isTornDown)
        XCTAssertEqual(next.viewportSize, larger)
        XCTAssertEqual(controller.cameraPose.yaw, 8, accuracy: 0.0001)
        XCTAssertEqual(next.cameraNode.position.x,
                       CGFloat(Scene3DCameraController.Geometry.worldPosition(for: .init(yaw: 8, pitch: 0),
                                                                              distance: next.cameraDistance).x),
                       accuracy: 0.0001)
        XCTAssertEqual(loader.callCount, 1)
    }

    // MARK: - Input and frames

    func testClickRoutesTheHitToTheActionSink() async throws {
        let host = Scene3DFakeHost()
        host.candidates = [Scene3DHitRouter.Candidate(
            nodeNameChain: ["button"],
            worldNormal: SIMD3<Float>(0, 0, 1),
            worldPoint: SIMD3<Float>(0, 0, 0)
        )]
        var actions: [(String, Double?)] = []
        let (controller, _) = makeController(loader: Scene3DTestLoader(template: makeTemplate()),
                                             actionSink: { actions.append(($0, $1)) })
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)

        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerUp(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.0, "press")
        XCTAssertEqual(actions.first?.1, 0.5)
    }

    func testInertiaRunsOnlyUntilSettledAndPointerDownStopsIt() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, scheduler) = makeController(loader: loader, reduceMotion: { false })
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)

        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerDragged(to: CGPoint(x: 30, y: 10))
        controller.pointerUp(at: CGPoint(x: 30, y: 10))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(scheduler.startCount, 1)

        var frames = 0
        while scheduler.isRunning && frames < 400 {
            scheduler.fire(1.0 / 60.0)
            frames += 1
        }
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertGreaterThan(scheduler.stopCount, 0)
        XCTAssertTrue(controller.isCameraSettled)
        XCTAssertGreaterThan(controller.cameraPose.yaw, 8)
        // 20 pt × 0.4°/pt = 8° of drag, plus roughly velocity/decay ≈ 24° of
        // inertia. There is no artificial 30° yaw cap in the camera contract.
        XCTAssertLessThanOrEqual(controller.cameraPose.yaw, 35)

        // A new press while inertia is running stops the frame loop immediately.
        controller.pointerDown(at: CGPoint(x: 50, y: 10))
        controller.pointerDragged(to: CGPoint(x: 70, y: 10))
        controller.pointerUp(at: CGPoint(x: 70, y: 10))
        XCTAssertTrue(scheduler.isRunning)
        controller.pointerDown(at: CGPoint(x: 80, y: 10))
        XCTAssertFalse(scheduler.isRunning)
        _ = controller.resetView()
        XCTAssertFalse(scheduler.isRunning)
    }

    func testReduceMotionSettlesWithoutAFrameLoop() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, scheduler) = makeController(loader: loader, reduceMotion: { true })
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)

        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerDragged(to: CGPoint(x: 30, y: 10))
        controller.pointerUp(at: CGPoint(x: 30, y: 10))
        XCTAssertEqual(scheduler.startCount, 0)
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertTrue(controller.isCameraSettled)
        XCTAssertEqual(controller.cameraPose.yaw, 8, accuracy: 0.0001)
    }

    func testStopStopsTheFrameLoopAndInput() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, scheduler) = makeController(loader: loader, reduceMotion: { false })
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)

        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerDragged(to: CGPoint(x: 30, y: 10))
        controller.pointerUp(at: CGPoint(x: 30, y: 10))
        XCTAssertTrue(scheduler.isRunning)

        controller.stop()
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(controller.hitSession?.isActive == true)
        XCTAssertEqual(scheduler.startCount, 1)
    }

    // MARK: - Accessibility

    func testAccessibilityActionsAndReset() async throws {
        var actions: [(String, Double?)] = []
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, scheduler) = makeController(loader: loader,
                                                     actionSink: { actions.append(($0, $1)) })
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)

        XCTAssertEqual(controller.accessibilityElements.map(\.role), [.button, .reset])
        let pressActionID = try XCTUnwrap(controller.accessibilityElements.first?.actionID)
        XCTAssertTrue(controller.performAccessibilityAction(pressActionID))
        XCTAssertEqual(actions.first?.0, "press")
        XCTAssertEqual(actions.first?.1, 0.5)

        controller.pointerDown(at: CGPoint(x: 10, y: 10))
        controller.pointerDragged(to: CGPoint(x: 30, y: 10))
        controller.pointerUp(at: CGPoint(x: 30, y: 10))
        XCTAssertEqual(controller.cameraPose.yaw, 8, accuracy: 0.0001)

        XCTAssertTrue(controller.performAccessibilityAction(Scene3DAccessibilityModel.resetViewElementID))
        XCTAssertEqual(controller.cameraPose, .init())
        XCTAssertEqual(instance.cameraNode.position.z, CGFloat(instance.cameraDistance), accuracy: 0.0001)
        XCTAssertFalse(controller.performAccessibilityAction(Scene3DAccessibilityModel.resetViewElementID))
        XCTAssertFalse(scheduler.isRunning)

        controller.stop()
        XCTAssertFalse(controller.performAccessibilityAction(pressActionID))
    }

    // MARK: - Configuration and isolation

    func testConfigureWithoutChangesIsANoOp() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.start()
        await waitForReady(controller)
        let generation = controller.generation
        let instance = try XCTUnwrap(controller.instance)

        controller.configure(descriptor: baseDescriptor(),
                             pluginID: "test.plugin",
                             assetDirectory: directory,
                             artwork: nil,
                             palette: .system())
        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(loader.callCount, 1)
        XCTAssertTrue(controller.instance === instance)
        XCTAssertEqual(controller.state, .ready(instance.identity))
    }

    /// 播放时进度每秒变化：只重绘贴图，场景实例、镜头姿态与宿主挂载都不能重建，否则模型会闪烁。
    func testSurfaceOnlyChangeRepaintsInPlaceWithoutRebuilding() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        let first = descriptorWithSurface(content: .text(value: "0:01", style: .body, lines: nil))
        controller.configure(descriptor: first, pluginID: "test.plugin", assetDirectory: directory,
                             artwork: nil, palette: .system())
        controller.start()
        await waitForReady(controller)
        let instance = try XCTUnwrap(controller.instance)
        let generation = controller.generation

        let second = descriptorWithSurface(content: .text(value: "0:02", style: .body, lines: nil))
        controller.configure(descriptor: second, pluginID: "test.plugin", assetDirectory: directory,
                             artwork: nil, palette: .system())

        XCTAssertTrue(controller.instance === instance)
        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.state, .ready(instance.identity))
        XCTAssertEqual(controller.descriptor, second)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testSurfaceSymbolChangeRepaintsWithoutRebuilding() async throws {
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        let first = descriptorWithSurface(content: .image(source: .symbol("pause.fill"), size: .m, corner: nil))
        controller.configure(descriptor: first, pluginID: "test.plugin", assetDirectory: directory,
                             artwork: nil, palette: .system())
        controller.start()
        await waitForReady(controller)
        let oldInstance = try XCTUnwrap(controller.instance)
        let oldMaterial = try XCTUnwrap(oldInstance.contentRoot.childNode(withName: "screen", recursively: true)?.geometry?.firstMaterial)

        let second = descriptorWithSurface(content: .image(source: .symbol("play.fill"), size: .m, corner: nil))
        controller.configure(descriptor: second, pluginID: "test.plugin", assetDirectory: directory,
                             artwork: nil, palette: .system())
        await waitForReady(controller)

        XCTAssertTrue(controller.instance === oldInstance)
        let newMaterial = try XCTUnwrap(controller.instance?.contentRoot.childNode(withName: "screen", recursively: true)?.geometry?.firstMaterial)
        XCTAssertTrue(newMaterial === oldMaterial)
        XCTAssertEqual(controller.descriptor, second)
    }

    func testConfigureSwitchTearsDownTheOldSceneBeforeLoading() async throws {
        let host = Scene3DFakeHost()
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (controller, _) = makeController(loader: loader)
        controller.updateSlotSize(slot)
        controller.attach(host: host)
        controller.start()
        await waitForReady(controller)
        let old = try XCTUnwrap(controller.instance)

        controller.configure(descriptor: baseDescriptor(key: "second"),
                             pluginID: "second.plugin",
                             assetDirectory: directory,
                             artwork: nil,
                             palette: .system())
        XCTAssertTrue(old.isTornDown)
        XCTAssertNil(host.mounted.last ?? nil)

        await waitForReady(controller)
        let current = try XCTUnwrap(controller.instance)
        XCTAssertEqual(current.identity.pluginID, "second.plugin")
        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(controller.state, .ready(current.identity))
    }

    func testTwoControllersForTheSamePluginDoNotShareInstanceState() async throws {
        let cache = PluginScene3DAssetCache(capacity: 4)
        let loader = Scene3DTestLoader(template: makeTemplate())
        let (first, firstScheduler) = makeController(loader: loader, cache: cache)
        let (second, secondScheduler) = makeController(loader: loader, cache: cache)

        first.updateSlotSize(slot)
        first.start()
        await waitForReady(first)
        second.updateSlotSize(slot)
        second.start()
        await waitForReady(second)

        XCTAssertEqual(loader.callCount, 1, "the second controller must reuse the cached template")
        let firstInstance = try XCTUnwrap(first.instance)
        let secondInstance = try XCTUnwrap(second.instance)
        XCTAssertFalse(firstInstance === secondInstance)
        XCTAssertFalse(firstInstance.scene === secondInstance.scene)
        XCTAssertEqual(firstInstance.identity, secondInstance.identity)

        first.pointerDown(at: CGPoint(x: 10, y: 10))
        first.pointerDragged(to: CGPoint(x: 30, y: 10))
        first.pointerUp(at: CGPoint(x: 30, y: 10))
        XCTAssertEqual(first.cameraPose.yaw, 8, accuracy: 0.0001)
        XCTAssertEqual(second.cameraPose.yaw, 0, accuracy: 0.0001)
        XCTAssertEqual(firstScheduler.startCount, 0)
        XCTAssertEqual(secondScheduler.startCount, 0)
        XCTAssertFalse(secondInstance.isTornDown)

        first.unload()
        XCTAssertNil(first.instance)
        XCTAssertFalse(secondInstance.isTornDown)
        XCTAssertNotNil(second.instance)
        XCTAssertEqual(second.state, .ready(secondInstance.identity))
    }

    // MARK: - Async helpers

    private func waitForReady(_ controller: PluginScene3DController,
                              timeout: TimeInterval = 3) async {
        await waitFor(controller, "ready", timeout: timeout) {
            if case .ready = controller.state { return controller.instance != nil }
            return false
        }
    }

    private func waitForFallback(_ controller: PluginScene3DController,
                                 timeout: TimeInterval = 3) async {
        await waitFor(controller, "fallback", timeout: timeout) {
            if case .fallback = controller.state { return true }
            return false
        }
    }

    private func waitFor(_ controller: PluginScene3DController,
                         _ message: String,
                         timeout: TimeInterval = 3,
                         until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("等待超时：\(message)，当前 state=\(controller.state)，generation=\(controller.generation)")
    }

    // MARK: - Builders

    private func makeController(
        loader: Scene3DTestLoader,
        descriptor: PluginScene3DDescriptor? = nil,
        cache: PluginScene3DAssetCache? = nil,
        pluginID: String = "test.plugin",
        dataReader: @escaping (URL) throws -> Data = { _ in Data("glb".utf8) },
        reduceMotion: @escaping () -> Bool = { true },
        actionSink: @escaping (String, Double?) -> Void = { _, _ in }
    ) -> (PluginScene3DController, Scene3DFakeFrameScheduler) {
        let scheduler = Scene3DFakeFrameScheduler()
        let controller = PluginScene3DController(
            descriptor: descriptor ?? baseDescriptor(),
            pluginID: pluginID,
            assetDirectory: directory,
            loader: loader,
            cache: cache ?? PluginScene3DAssetCache(capacity: 4),
            dataReader: dataReader,
            rasterizerFactory: { Scene3DFakeRasterizer(image: Self.makeImage()) },
            frameSchedulerFactory: { scheduler },
            reduceMotion: reduceMotion,
            resetViewLabel: "Reset",
            actionSink: actionSink
        )
        return (controller, scheduler)
    }

    private func makeTemplate() -> SCNScene {
        let scene = SCNScene()
        let model = SCNNode()
        model.name = "model"

        let screen = SCNNode(geometry: SCNPlane(width: 2, height: 1))
        screen.name = "screen"
        model.addChildNode(screen)

        let button = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
        button.name = "button"
        button.position = SCNVector3(0, -1.5, 0)
        model.addChildNode(button)

        scene.rootNode.addChildNode(model)
        return scene
    }

    private func baseDescriptor(key: String = "k") -> PluginScene3DDescriptor {
        PluginScene3DDescriptor(
            key: key,
            asset: "a.glb",
            hits: [PluginScene3DHit(node: "button", id: "press", label: "Play", value: 0.5)],
            fallback: .text(value: "fallback", style: .body, lines: nil)
        )
    }

    private func descriptorWithSurface(content: PluginUINode) -> PluginScene3DDescriptor {
        var descriptor = baseDescriptor()
        descriptor.surfaces = [
            PluginScene3DSurface(node: "screen", size: .init(width: 64, height: 64), content: content)
        ]
        return descriptor
    }

    private static func makeImage(width: Int = 4, height: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

// MARK: - Test doubles

@MainActor
private final class Scene3DFakeHost: PluginScene3DSceneHosting {
    var mounted: [SCNScene?] = []
    var refreshCount = 0
    var candidates: [Scene3DHitRouter.Candidate] = []

    func mountScene(_ scene: SCNScene?) {
        mounted.append(scene)
    }

    func refreshDisplay() {
        refreshCount += 1
    }

    func hitCandidates(at point: CGPoint) -> [Scene3DHitRouter.Candidate] {
        candidates
    }
}

@MainActor
private final class Scene3DFakeFrameScheduler: PluginScene3DFrameScheduling {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var tick: (@MainActor (TimeInterval) -> Void)?

    func start(tick: @escaping @MainActor (TimeInterval) -> Void) {
        startCount += 1
        self.tick = tick
        isRunning = true
    }

    func stop() {
        if isRunning {
            stopCount += 1
        }
        isRunning = false
        tick = nil
    }

    func fire(_ delta: TimeInterval) {
        tick?(delta)
    }
}

@MainActor
private final class Scene3DFakeRasterizer: PluginSurfaceRasterizing {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
    }

    func rasterize(_ plan: PluginSurfaceRasterPlan) -> PluginSurfaceTexture? {
        PluginSurfaceTexture(
            image: image,
            pointSize: plan.pointSize,
            pixelsPerPoint: plan.pixelsPerPoint,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            orientation: .up,
            contentSignature: plan.contentSignature
        )
    }
}

/// Runs on the controller's detached task, so counters are lock-protected and
/// the optional gate lets a test hold one load open while it cancels it.
private final class Scene3DTestLoader: PluginScene3DAssetLoading {
    enum Outcome {
        case success
        case failure(PluginScene3DFailure)
    }

    private let template: SCNScene
    private let outcome: Outcome
    private let gateFirstCall: Bool
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var released = false

    init(template: SCNScene, outcome: Outcome = .success, gateFirstCall: Bool = false) {
        self.template = template
        self.outcome = outcome
        self.gateFirstCall = gateFirstCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func releaseFirstCall() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        gate.signal()
    }

    func load(data: Data, identity: PluginScene3DIdentity) throws -> PluginScene3DAsset {
        lock.lock()
        calls += 1
        let index = calls
        lock.unlock()

        if index == 1 && gateFirstCall {
            gate.wait()
        }

        switch outcome {
        case .failure(let failure):
            throw failure
        case .success:
            return PluginScene3DAsset(
                identity: identity,
                templateScene: template,
                nodeNames: ["model", "screen", "button"],
                fileBytes: data.count,
                report: GLBPreflight.Report(
                    nodeNames: ["model", "screen", "button"],
                    meshCount: 2,
                    nodeCount: 3,
                    triangleCount: 12,
                    decodedTextureBytes: 0
                )
            )
        }
    }
}

final class PluginScene3DAssetFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene3d-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("pkg"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRegularFileInsidePackagePasses() throws {
        let pkg = dir.appendingPathComponent("pkg")
        let file = pkg.appendingPathComponent("a.glb")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(PluginScene3DAssetFile.violation(file, within: pkg))
    }

    func testMissingFileIsLeftToReader() {
        let pkg = dir.appendingPathComponent("pkg")
        XCTAssertNil(PluginScene3DAssetFile.violation(pkg.appendingPathComponent("none.glb"), within: pkg))
    }

    func testSymlinkEscapingPackageIsRejected() throws {
        let pkg = dir.appendingPathComponent("pkg")
        let outside = dir.appendingPathComponent("outside.glb")
        try Data("x".utf8).write(to: outside)
        let link = pkg.appendingPathComponent("link.glb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNotNil(PluginScene3DAssetFile.violation(link, within: pkg))
    }

    func testOversizedFileIsRejectedBeforeReading() throws {
        let pkg = dir.appendingPathComponent("pkg")
        let file = pkg.appendingPathComponent("big.glb")
        try Data(count: GLBPreflight.Budget.maxFileBytes + 1).write(to: file)
        XCTAssertNotNil(PluginScene3DAssetFile.violation(file, within: pkg))
    }
}
