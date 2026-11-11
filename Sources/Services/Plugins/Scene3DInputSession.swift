//
//  Scene3DInputSession.swift
//  Switchly
//
//  T05: the single input entry point for a `scene3d` scene. It owns the
//  pointer classifier, orbit camera and action sink, and it gates every
//  callback on the scene lifecycle: once `stop()` runs (hide, uninstall,
//  panel close) no pointer, inertia or accessibility callback may escape.
//
//  T06 drives frames by calling `advance(by:)` while `isCameraSettled` is
//  false. The host and preview share this class; no plugin-specific branching
//  lives here.
//

import CoreGraphics
import Foundation
import simd

/// Adapter boundary. The SceneKit implementation lives in
/// `Scene3DHitTestAdapter`; tests inject a fake.
@MainActor
protocol Scene3DHitProviding: AnyObject {
    func hitCandidates(at point: CGPoint) -> [Scene3DHitRouter.Candidate]
}

@MainActor
final class Scene3DInputSession {
    /// Weak: the host controller owns the session and is also the hit
    /// provider. A strong reference here would close a controller ↔ session
    /// retain cycle, so neither object could deallocate without `unload()`.
    private weak var hitProvider: Scene3DHitProviding?
    private let actionSink: (String, Double?) -> Void
    private let reduceMotion: () -> Bool
    private let cameraPosition: (Scene3DCameraController.Pose) -> SIMD3<Float>

    private var classifier = Scene3DPointerClassifier()
    private(set) var camera: Scene3DCameraController
    private var router: Scene3DHitRouter

    private(set) var isActive = false

    /// Called whenever the pose changed through input or inertia. The panel
    /// uses it to apply the camera transform; it is never called after
    /// `stop()`.
    var onCameraChanged: ((Scene3DCameraController.Pose) -> Void)?

    init(hitProvider: Scene3DHitProviding,
         camera: Scene3DCameraController = Scene3DCameraController(),
         hits: [Scene3DHitRouter.Hit],
         reduceMotion: @escaping () -> Bool,
         cameraPosition: @escaping (Scene3DCameraController.Pose) -> SIMD3<Float> = {
             Scene3DCameraController.Geometry.worldPosition(for: $0)
         },
         actionSink: @escaping (String, Double?) -> Void) {
        self.hitProvider = hitProvider
        self.camera = camera
        self.router = Scene3DHitRouter(hits: hits)
        self.reduceMotion = reduceMotion
        self.cameraPosition = cameraPosition
        self.actionSink = actionSink
    }

    var cameraPose: Scene3DCameraController.Pose { camera.pose }
    var isCameraSettled: Bool { camera.isSettled }

    func start() {
        isActive = true
        classifier.cancel()
        camera.stopInertia()
    }

    /// Stops input and inertia. Safe to call repeatedly. Hit candidates that
    /// arrive late are ignored because every entry point checks `isActive`.
    func stop() {
        isActive = false
        classifier.cancel()
        camera.stopInertia()
    }

    // MARK: - Pointer

    func pointerDown(at point: CGPoint) {
        guard isActive else { return }
        camera.stopInertia()
        classifier.down(at: point)
    }

    func pointerDragged(to point: CGPoint) {
        guard isActive, classifier.isDown else { return }
        let previous = classifier.lastPoint ?? classifier.downPoint ?? point
        let wasDragging = classifier.isDragging
        classifier.moved(to: point)

        guard classifier.isDragging else { return }
        // On the first move past the threshold apply the full travel from the
        // down point; a click therefore never nudges the camera.
        let delta: CGVector
        if wasDragging {
            delta = CGVector(dx: point.x - previous.x, dy: point.y - previous.y)
        } else if let downPoint = classifier.downPoint {
            delta = CGVector(dx: point.x - downPoint.x, dy: point.y - downPoint.y)
        } else {
            delta = .zero
        }
        if camera.drag(by: delta) {
            onCameraChanged?(camera.pose)
        }
    }

    func pointerUp(at point: CGPoint) {
        guard isActive, classifier.isDown else { return }
        let outcome = classifier.up(at: point)
        switch outcome {
        case .click(let downPoint):
            dispatchClick(at: downPoint)
        case .drag:
            camera.endDrag(reduceMotion: reduceMotion())
        case .none:
            break
        }
    }

    func pointerCancelled() {
        guard isActive else { return }
        classifier.cancel()
    }

    // MARK: - Frames

    /// Advances inertia. Returns whether the frame loop should continue.
    @discardableResult
    func advance(by deltaTime: TimeInterval) -> Bool {
        guard isActive, !camera.isSettled else { return false }
        let before = camera.pose
        camera.advance(by: deltaTime)
        if camera.pose != before {
            onCameraChanged?(camera.pose)
        }
        return !camera.isSettled
    }

    // MARK: - Programmatic turn

    /// Turns the model one full revolution (or a quarter turn under Reduce
    /// Motion, where animation is dropped but every side stays reachable).
    /// Returns whether anything started or moved.
    @discardableResult
    func spin(_ direction: Scene3DCameraController.SpinDirection) -> Bool {
        guard isActive else { return false }
        classifier.cancel()
        if reduceMotion() {
            let changed = camera.turn(direction)
            if changed { onCameraChanged?(camera.pose) }
            return changed
        }
        return camera.beginSpin(direction)
    }

    // MARK: - Accessibility and keyboard

    /// Resets the orbit angle. Returns whether the pose changed.
    @discardableResult
    func resetView() -> Bool {
        guard isActive else { return false }
        let changed = camera.reset()
        if changed { onCameraChanged?(camera.pose) }
        return changed
    }

    /// Performs a semantic action from VoiceOver or the keyboard. Text and
    /// disabled elements have no action; reset is handled independently of
    /// geometry.
    @discardableResult
    func performAccessibilityAction(_ actionID: String) -> Bool {
        guard isActive else { return false }
        if actionID == Scene3DAccessibilityModel.resetViewElementID {
            resetView()
            return true
        }
        guard let hit = router.hit(actionID: actionID), hit.enabled else { return false }
        actionSink(hit.actionID, hit.value)
        return true
    }

    // MARK: - Private

    private func dispatchClick(at point: CGPoint) {
        // The provider may already be gone (host torn down without `stop()`);
        // a late click must not resurrect it or dispatch a stale action.
        guard let hitProvider else { return }
        let candidates = hitProvider.hitCandidates(at: point)
        guard let action = router.route(candidates: candidates,
                                        cameraPosition: cameraPosition(camera.pose)) else {
            return
        }
        actionSink(action.id, action.value)
    }
}
