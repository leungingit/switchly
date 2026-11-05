//
//  FourFingerHoldDetector.swift
//  Switchly
//
//  Recognises "four fingers resting still" so the HUD can show where the
//  current desktop sits in the grid. Like the swipe classifier it only sees
//  finger count + centroid + timestamp, so it is driven by synthetic frames
//  in unit tests.
//

import Foundation
import CoreGraphics

enum FourFingerHoldEvent: Equatable {
    /// Four fingers stayed put long enough.
    case began
    /// The fingers lifted after `began`.
    case ended
}

enum HoldDefaults {
    /// How long four fingers must rest before the locate HUD appears.
    static let durationSeconds: TimeInterval = 1.0
    /// Centroid drift that turns a rest into a swipe attempt, in millimetres.
    /// Smaller than the swipe threshold, so a swipe never counts as a hold.
    static let maxDriftMM: Double = 4
}

struct FourFingerHoldDetector {
    var duration: TimeInterval = HoldDefaults.durationSeconds
    var maxDriftMM: Double = HoldDefaults.maxDriftMM
    var dropoutMS: Double = SwipeDefaults.dropoutMS

    private var startedAt: TimeInterval?
    private var anchor: CGPoint = .zero
    private var belowSince: TimeInterval?
    /// Moved, or a fifth finger landed: no hold until every finger lifts.
    private var cancelled = false
    private var isHolding = false

    mutating func reset() {
        startedAt = nil
        belowSince = nil
        cancelled = false
        isHolding = false
    }

    /// Feeds one frame; returns an event when the hold begins or ends.
    mutating func process(
        fingers: Int,
        centroidMM: CGPoint,
        timestamp: TimeInterval
    ) -> FourFingerHoldEvent? {
        guard let started = startedAt else {
            if fingers == SwipeDefaults.minimumFingers {
                startedAt = timestamp
                anchor = centroidMM
                belowSince = nil
                cancelled = false
            }
            return nil
        }

        if fingers == 0 { return end() }

        if fingers >= SwipeDefaults.minimumFingers {
            belowSince = nil
            // Once shown, the HUD stays until the fingers lift, so a small
            // wobble cannot flicker it.
            guard !isHolding, !cancelled else { return nil }
            if fingers > SwipeDefaults.minimumFingers
                || hypot(centroidMM.x - anchor.x, centroidMM.y - anchor.y) > maxDriftMM {
                cancelled = true
                return nil
            }
            if timestamp - started >= duration {
                isHolding = true
                return .began
            }
            return nil
        }

        let since = belowSince ?? timestamp
        belowSince = since
        return (timestamp - since) * 1000 >= dropoutMS ? end() : nil
    }

    private mutating func end() -> FourFingerHoldEvent? {
        let wasHolding = isHolding
        reset()
        return wasHolding ? .ended : nil
    }
}
