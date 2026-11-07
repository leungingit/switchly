//
//  Scene3DCameraController.swift
//  Switchly
//
//  T05: generic orbit camera for `scene3d`. Owns yaw / pitch, pitch clamping,
//  Reduce Motion aware inertia and view reset. This type is pure Swift so the
//  same rules are unit-tested and shared by the host and the preview.
//
//  The camera orbits the model origin. Drag right turns the model right; drag
//  up tilts it up. Horizontal rotation wraps at ±180°, vertical pitch is
//  clamped to the plugin-provided limits.
//

import CoreGraphics
import Foundation

struct Scene3DCameraController {
    /// Angles in degrees. `yaw` is normalised to (-180, 180]; `pitch` is
    /// clamped to the configured range.
    struct Pose: Equatable {
        var yaw: Double
        var pitch: Double

        init(yaw: Double = 0, pitch: Double = 0) {
            self.yaw = yaw
            self.pitch = pitch
        }
    }

    /// Declared by the plugin (`rotate.horizontal`, `rotate.vertical`,
    /// `rotate.pitchMin`, `rotate.pitchMax`). A disabled axis ignores drags
    /// and inertia on that axis while keeping the other axis live.
    struct Limits: Equatable {
        var horizontal: Bool
        var vertical: Bool
        var pitchMin: Double
        var pitchMax: Double

        init(horizontal: Bool = true,
             vertical: Bool = true,
             pitchMin: Double = -55,
             pitchMax: Double = 55) {
            self.horizontal = horizontal
            self.vertical = vertical
            // Reversed limits are normalised instead of trapping the camera.
            self.pitchMin = min(pitchMin, pitchMax)
            self.pitchMax = max(pitchMin, pitchMax)
        }
    }

    struct Tuning: Equatable {
        /// Degrees of rotation per point of pointer travel.
        var degreesPerPoint: Double
        /// Degrees per second of inertia per degree of the last drag delta.
        var inertiaRate: Double
        /// Exponential velocity decay, in nepers per second.
        var inertiaDecayPerSecond: Double
        /// Velocities below this (degrees per second) stop the frame loop.
        var stopVelocity: Double

        init(degreesPerPoint: Double = 0.4,
             inertiaRate: Double = 9,
             inertiaDecayPerSecond: Double = 3,
             stopVelocity: Double = 0.5) {
            self.degreesPerPoint = degreesPerPoint
            self.inertiaRate = inertiaRate
            self.inertiaDecayPerSecond = inertiaDecayPerSecond
            self.stopVelocity = stopVelocity
        }
    }

    /// Camera orbit geometry shared with hit routing.
    enum Geometry {
        /// Camera position for a pose on a sphere around the model origin.
        /// Zero pitch / yaw puts the camera on +Z, looking back at the model.
        static func worldPosition(for pose: Pose, distance: Float = 4) -> SIMD3<Float> {
            let yaw = Float(pose.yaw) * .pi / 180
            let pitch = Float(pose.pitch) * .pi / 180
            return SIMD3(distance * sin(yaw) * cos(pitch),
                         distance * sin(pitch),
                         distance * cos(yaw) * cos(pitch))
        }
    }

    let initialPose: Pose
    let limits: Limits
    let tuning: Tuning

    private(set) var pose: Pose
    /// Degrees per second applied by `advance(by:)` after a flick.
    private(set) var velocity: CGVector = .zero

    init(initialPose: Pose = Pose(),
         limits: Limits = Limits(),
         tuning: Tuning = Tuning()) {
        self.initialPose = initialPose
        self.limits = limits
        self.tuning = tuning
        self.pose = initialPose
    }

    var isSettled: Bool { velocity == .zero }

    /// Applies one pointer delta (points, top-left origin). Returns whether the
    /// pose changed. Velocity is retained as a flick candidate until
    /// `endDrag(reduceMotion:)`.
    @discardableResult
    mutating func drag(by delta: CGVector) -> Bool {
        let yawDelta = limits.horizontal ? Double(delta.dx) * tuning.degreesPerPoint : 0
        let pitchDelta = limits.vertical ? -Double(delta.dy) * tuning.degreesPerPoint : 0
        guard yawDelta != 0 || pitchDelta != 0 else { return false }

        pose.yaw += yawDelta
        pose.pitch += pitchDelta
        clampPose()
        velocity = CGVector(dx: yawDelta * tuning.inertiaRate,
                            dy: pitchDelta * tuning.inertiaRate)
        return true
    }

    /// Ends a drag. Under Reduce Motion inertia is dropped so the view stops
    /// exactly where the pointer left it; direct dragging still applies.
    mutating func endDrag(reduceMotion: Bool) {
        if reduceMotion { stopInertia() }
    }

    /// Stops inertia immediately. Hidden scenes and lifecycle shutdown must
    /// not keep a frame loop alive.
    mutating func stopInertia() {
        velocity = .zero
    }

    /// Advances inertia. Returns whether another frame is needed (the pose may
    /// already be clamped while the velocity is still decaying).
    @discardableResult
    mutating func advance(by deltaTime: TimeInterval) -> Bool {
        guard deltaTime > 0, !isSettled else { return false }

        if limits.horizontal { pose.yaw += velocity.dx * deltaTime }
        if limits.vertical { pose.pitch += velocity.dy * deltaTime }
        clampPose()

        let decay = exp(-tuning.inertiaDecayPerSecond * deltaTime)
        velocity.dx *= decay
        velocity.dy *= decay
        if abs(velocity.dx) < tuning.stopVelocity, abs(velocity.dy) < tuning.stopVelocity {
            velocity = .zero
        }
        return true
    }

    /// Returns the camera to its declared initial angle and stops inertia.
    @discardableResult
    mutating func reset() -> Bool {
        let changed = pose != initialPose || velocity != .zero
        pose = initialPose
        velocity = .zero
        return changed
    }

    private mutating func clampPose() {
        pose.pitch = min(max(pose.pitch, limits.pitchMin), limits.pitchMax)
        pose.yaw = Self.wrappedYaw(pose.yaw)
    }

    private static func wrappedYaw(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped < -180 { wrapped += 360 }
        return wrapped
    }
}
