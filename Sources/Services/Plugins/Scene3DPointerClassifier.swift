//
//  Scene3DPointerClassifier.swift
//  Switchly
//
//  T05: distinguishes a click from a drag for `scene3d`. A pointer that
//  travels less than `dragThreshold` points between down and up is a click;
//  anything further becomes a drag and must not dispatch a hit action.
//
//  Framework-free on purpose so the threshold rule is identical in the host
//  panel, the preview and unit tests.
//

import CoreGraphics

struct Scene3DPointerClassifier {
    enum Outcome: Equatable {
        /// Down and up stayed inside the threshold. The associated point is
        /// the down location, where the hit test must be evaluated.
        case click(CGPoint)
        case drag
        case none
    }

    /// Euclidean travel, in points, before a gesture is treated as a drag.
    static let dragThreshold: CGFloat = 4

    private(set) var downPoint: CGPoint?
    private(set) var lastPoint: CGPoint?
    private(set) var isDragging = false

    var isDown: Bool { downPoint != nil }

    mutating func down(at point: CGPoint) {
        downPoint = point
        lastPoint = point
        isDragging = false
    }

    /// Records pointer movement. Returns whether the gesture is a drag after
    /// this move; movement below the threshold is ignored.
    @discardableResult
    mutating func moved(to point: CGPoint) -> Bool {
        guard let downPoint else { return false }
        lastPoint = point
        if isDragging { return true }
        if Self.distance(from: downPoint, to: point) >= Self.dragThreshold {
            isDragging = true
        }
        return isDragging
    }

    /// Ends the gesture. A click only exists when the pointer never crossed
    /// the drag threshold.
    mutating func up(at point: CGPoint) -> Outcome {
        guard let downPoint else { return .none }
        lastPoint = point
        defer { self.downPoint = nil; self.lastPoint = nil; self.isDragging = false }
        if isDragging || Self.distance(from: downPoint, to: point) >= Self.dragThreshold {
            return .drag
        }
        return .click(downPoint)
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasActive = downPoint != nil || isDragging
        downPoint = nil
        lastPoint = nil
        isDragging = false
        return wasActive
    }

    static func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = rhs.x - lhs.x
        let dy = rhs.y - lhs.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
