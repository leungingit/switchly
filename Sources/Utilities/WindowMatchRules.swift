//
//  WindowMatchRules.swift
//  Switchly
//
//  Pure, dependency-free matching rules used to identify which Accessibility
//  window corresponds to a CoreGraphics window.
//
//  These rules live in their own file (rather than inside AccessibilityService)
//  because they are the part of the switch pipeline that is worth unit testing:
//  they encode the *policy* (how titles from two different sources are
//  compared, how geometry is compared, how z-order correlation maps an index
//  between the two orderings) while the service only performs the queries.
//
//  Background: the private `AXWindowNumber` attribute is not exposed by most
//  apps (measured: nil in 116/116 real switches), and the title reported by the
//  Accessibility API frequently differs from the CoreGraphics window name —
//  Chrome, for instance, reports `新标签页 - Google Chrome - alice` on the AX
//  side while the CG window list reports `新标签页`. Strict equality therefore
//  never matches, the identification silently degrades to geometry only, and
//  every window of a maximized app scores the same. That is the root cause of
//  "clicking a preview card does not switch windows" for multi-window apps.
//

import Foundation
import CoreGraphics

/// Rules for comparing a window title coming from the Accessibility API with
/// the one coming from the CoreGraphics window list.
enum WindowTitleRules {
    /// Normalizes a title for cross-source comparison.
    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// How well two titles match, as a small ordinal scale.
    ///
    /// - `2`: identical after normalization.
    /// - `1`: one title extends the other across a `" - "` boundary, which is
    ///   the shape apps append their product/profile name with
    ///   (`新标签页` vs `新标签页 - Google Chrome - alice`). The boundary is
    ///   required so that unrelated titles sharing a prefix
    ///   (`Damage` vs `DamageControl`) never match.
    /// - `0`: no usable match (including the case where either side is empty —
    ///   an unknown title must never be treated as agreement).
    static func matchStrength(axTitle: String, cgTitle: String) -> Int {
        let ax = normalized(axTitle)
        let cg = normalized(cgTitle)
        guard !ax.isEmpty, !cg.isEmpty else { return 0 }
        if ax == cg { return 2 }
        if let suffix = ax.strippingPrefix(cg), suffix.hasPrefix(" - ") { return 1 }
        if let suffix = cg.strippingPrefix(ax), suffix.hasPrefix(" - ") { return 1 }
        return 0
    }

    /// Score contribution of a title match. An exact match is worth the
    /// acceptance threshold on its own; an extended match is worth noticeably
    /// less so that an exact match always outranks it.
    static func score(axTitle: String, cgTitle: String) -> Int {
        switch matchStrength(axTitle: axTitle, cgTitle: cgTitle) {
        case 2: return 40
        case 1: return 30
        default: return 0
        }
    }
}

private extension String {
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Rules for comparing window geometry across the two APIs.
enum WindowGeometryRules {
    static let sizeTolerance: CGFloat = 4
    static let positionTolerance: CGFloat = 8

    static func isSameSize(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.width - rhs.width) <= sizeTolerance
            && abs(lhs.height - rhs.height) <= sizeTolerance
    }

    static func isSamePosition(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= positionTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= positionTolerance
    }

    /// Whether two windows are indistinguishable by geometry, i.e. exactly the
    /// ambiguous case where score-based identification cannot work any more.
    static func isSameClass(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        isSameSize(lhs, rhs) && isSamePosition(lhs, rhs)
    }
}

/// Correlates the two window orderings.
///
/// `CGWindowListCopyWindowInfo` always enumerates front-to-back, while the
/// direction of `kAXWindowsAttribute` is app-dependent, so the direction is
/// calibrated at runtime and only the *relative* order inside a geometry class
/// is used — no titles, no window numbers.
enum WindowZOrderPairing {
    /// Maps a window's position inside its geometry class (counted
    /// front-to-back, CoreGraphics order) to its index inside the
    /// Accessibility ordering of the same class.
    ///
    /// Returns `nil` when the class holds no usable correlation, so callers
    /// fall back to scored matching instead of guessing.
    static func index(inClass index: Int, classCount: Int, axIsFrontToBack: Bool) -> Int? {
        guard classCount > 0, index >= 0, index < classCount else { return nil }
        return axIsFrontToBack ? index : classCount - 1 - index
    }
}
