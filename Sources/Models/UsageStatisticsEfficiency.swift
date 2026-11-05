//
//  UsageStatisticsEfficiency.swift
//  Switchly
//
//  The "how much did shortcuts save me" model: a counterfactual mouse-only
//  baseline compared against what actually happened.
//
//  Counts are measured; the per-use durations are user-adjustable estimates
//  (see the plan's sections 6.3 and 8.5). Keeping the two apart is what makes
//  the panel honest -- and it is why nothing here reads or writes a file.
//

import Foundation

// MARK: - Baseline values

/// A flow is one meaningful completed action.
enum EfficiencyFeature: String, Codable, CaseIterable, Hashable {
    /// Open the preview panel and confirm a window from it.
    case preview
    /// Jump straight to a window without ever showing the panel.
    case quickSwitch
    /// Summon the workspace bar. Secondary, but part of the total.
    case workspace
}

enum EfficiencyBaselinePreset: String, Codable, CaseIterable, Hashable {
    case conservative
    /// Raw value is the historical word, not the Swift keyword.
    case standard = "default"
    case aggressive
    case custom
}

struct EfficiencyBaselineValues: Codable, Equatable {
    var previewKeyboardSeconds: Double
    var previewMouseSeconds: Double
    var quickSwitchKeyboardSeconds: Double
    var quickSwitchMouseSeconds: Double
    var workspaceKeyboardSeconds: Double
    var workspaceMouseSeconds: Double

    static let allowedRange: ClosedRange<Double> = 0.5...60

    /// Recommended defaults: this machine's common magnitudes, rounded.
    static let standard = EfficiencyBaselineValues(
        previewKeyboardSeconds: 2.5,
        previewMouseSeconds: 12.0,
        quickSwitchKeyboardSeconds: 0.5,
        quickSwitchMouseSeconds: 8.0,
        workspaceKeyboardSeconds: 1.0,
        workspaceMouseSeconds: 6.0
    )

    static let conservative = EfficiencyBaselineValues(
        previewKeyboardSeconds: 3.0,
        previewMouseSeconds: 9.0,
        quickSwitchKeyboardSeconds: 1.0,
        quickSwitchMouseSeconds: 6.0,
        workspaceKeyboardSeconds: 1.5,
        workspaceMouseSeconds: 5.0
    )

    static let aggressive = EfficiencyBaselineValues(
        previewKeyboardSeconds: 2.0,
        previewMouseSeconds: 15.0,
        quickSwitchKeyboardSeconds: 0.3,
        quickSwitchMouseSeconds: 10.0,
        workspaceKeyboardSeconds: 0.8,
        workspaceMouseSeconds: 8.0
    )

    func keyboardSeconds(for feature: EfficiencyFeature) -> Double {
        switch feature {
        case .preview: return previewKeyboardSeconds
        case .quickSwitch: return quickSwitchKeyboardSeconds
        case .workspace: return workspaceKeyboardSeconds
        }
    }

    func mouseSeconds(for feature: EfficiencyFeature) -> Double {
        switch feature {
        case .preview: return previewMouseSeconds
        case .quickSwitch: return quickSwitchMouseSeconds
        case .workspace: return workspaceMouseSeconds
        }
    }

    /// A baseline is usable when every duration is a finite number inside the
    /// allowed band. "keyboard slower than mouse" is deliberately NOT rejected
    /// here: it is clamped to a zero saving where it is used, so the panel can
    /// never display a negative saving.
    var isUsable: Bool {
        let all = [previewKeyboardSeconds, previewMouseSeconds,
                   quickSwitchKeyboardSeconds, quickSwitchMouseSeconds,
                   workspaceKeyboardSeconds, workspaceMouseSeconds]
        return all.allSatisfy { value in
            value.isFinite && Self.allowedRange.contains(value)
        }
    }
}

struct EfficiencyBaseline: Equatable {
    var preset: EfficiencyBaselinePreset
    var values: EfficiencyBaselineValues

    static let recommended = EfficiencyBaseline(preset: .standard, values: .standard)

    static func values(for preset: EfficiencyBaselinePreset) -> EfficiencyBaselineValues {
        switch preset {
        case .conservative: return .conservative
        case .standard: return .standard
        case .aggressive: return .aggressive
        case .custom: return .standard
        }
    }

    /// Falls back to the recommended preset whenever the stored custom values
    /// are unusable, so a corrupt settings file cannot produce NaN savings.
    static func resolved(preset: EfficiencyBaselinePreset, custom: EfficiencyBaselineValues?) -> EfficiencyBaseline {
        if preset == .custom, let custom, custom.isUsable {
            return EfficiencyBaseline(preset: .custom, values: custom)
        }
        if preset == .custom {
            return .recommended
        }
        return EfficiencyBaseline(preset: preset, values: values(for: preset))
    }
}

// MARK: - Flows

struct EfficiencyFlow: Equatable {
    let feature: EfficiencyFeature
    let keyboardCount: Int
    let pointerCount: Int
    let keyboardSeconds: Double
    let mouseSeconds: Double

    /// Clamped at zero: a mis-configured baseline must never produce a
    /// negative saving on screen.
    var perUseSavedSeconds: Double {
        max(0, mouseSeconds - keyboardSeconds)
    }

    var savedSeconds: Double {
        Double(keyboardCount) * perUseSavedSeconds
    }

    var activityCount: Int { keyboardCount + pointerCount }
}

struct EfficiencySummary: Equatable {
    let savedSeconds: Double
    let baselineSeconds: Double
    let actualSeconds: Double
    let multiple: Double
    let keyboardCount: Int
    let pointerCount: Int

    static let empty = EfficiencySummary(savedSeconds: 0,
                                         baselineSeconds: 0,
                                         actualSeconds: 0,
                                         multiple: 1,
                                         keyboardCount: 0,
                                         pointerCount: 0)

    var hasActivity: Bool { keyboardCount + pointerCount > 0 }

    var keyboardShare: Double {
        let total = keyboardCount + pointerCount
        guard total > 0 else { return 0 }
        return Double(keyboardCount) / Double(total)
    }
}

enum EfficiencyMath {
    /// Completed flows only: an opened-but-not-confirmed preview is usage, but
    /// it is not a flow, so it does not enter the ratio.
    static func flows(_ totals: UsageTotals, baseline: EfficiencyBaseline) -> [EfficiencyFlow] {
        [
            EfficiencyFlow(feature: .preview,
                           keyboardCount: totals.switchKeyboard,
                           pointerCount: totals.switchPointer,
                           keyboardSeconds: baseline.values.keyboardSeconds(for: .preview),
                           mouseSeconds: baseline.values.mouseSeconds(for: .preview)),
            EfficiencyFlow(feature: .quickSwitch,
                           keyboardCount: totals.quickSwitchCount,
                           pointerCount: 0,
                           keyboardSeconds: baseline.values.keyboardSeconds(for: .quickSwitch),
                           mouseSeconds: baseline.values.mouseSeconds(for: .quickSwitch)),
            EfficiencyFlow(feature: .workspace,
                           keyboardCount: totals.workspaceKeyboard,
                           pointerCount: totals.workspacePointer,
                           keyboardSeconds: baseline.values.keyboardSeconds(for: .workspace),
                           mouseSeconds: baseline.values.mouseSeconds(for: .workspace))
        ]
    }

    static func summary(_ flows: [EfficiencyFlow], baseline: EfficiencyBaseline) -> EfficiencySummary {
        let saved = flows.reduce(0.0) { $0 + $1.savedSeconds }
        let baselineSeconds = flows.reduce(0.0) { partial, flow in
            partial + Double(flow.activityCount) * flow.mouseSeconds
        }
        let actualSeconds = flows.reduce(0.0) { partial, flow in
            partial
                + Double(flow.keyboardCount) * flow.keyboardSeconds
                + Double(flow.pointerCount) * flow.mouseSeconds
        }
        return EfficiencySummary(savedSeconds: saved,
                                 baselineSeconds: baselineSeconds,
                                 actualSeconds: actualSeconds,
                                 multiple: multiple(baselineSeconds: baselineSeconds, actualSeconds: actualSeconds),
                                 keyboardCount: flows.reduce(0) { $0 + $1.keyboardCount },
                                 pointerCount: flows.reduce(0) { $0 + $1.pointerCount })
    }

    /// One value per bucket, for the savings bar chart.
    static func savedSeconds(_ buckets: [StatisticsBucket], baseline: EfficiencyBaseline) -> [Double] {
        buckets.map { summary(flows($0.totals, baseline: baseline), baseline: baseline).savedSeconds }
    }

    /// baseline / actual, floored at 1 so "no activity" reads as neutral
    /// instead of infinite.
    static func multiple(baselineSeconds: Double, actualSeconds: Double) -> Double {
        guard baselineSeconds.isFinite, actualSeconds.isFinite, actualSeconds > 0 else { return 1 }
        return max(1, baselineSeconds / actualSeconds)
    }
}

// MARK: - Quick-switch attribution

/// Which of the three panel-less switch paths fired.
///
/// Returning an optional (rather than a set) is the type-level guarantee that
/// at most one path is counted for a single switch.
enum QuickSwitchAttribution {
    enum Scenario: String, Equatable {
        /// App shortcut, exactly one window, switched directly (AppDelegate).
        case singleWindowAutoSwitch
        /// The same, but reached from inside showWindows (shared shortcut).
        case panelScopedAutoSwitch
        /// The previous/next window shortcut for the frontmost app.
        case currentAppWindowRotation
    }

    static func source(for scenario: Scenario) -> UsageEventSource {
        switch scenario {
        case .singleWindowAutoSwitch, .panelScopedAutoSwitch:
            return .appShortcut
        case .currentAppWindowRotation:
            return .currentAppWindowShortcut
        }
    }

    static func scenario(appCount: Int,
                         autoSwitchIfSingle: Bool,
                         appWindowCount: Int,
                         viaPanel: Bool,
                         isCurrentAppWindowShortcut: Bool) -> Scenario? {
        if isCurrentAppWindowShortcut {
            return .currentAppWindowRotation
        }
        guard autoSwitchIfSingle, appWindowCount == 1 else { return nil }
        if viaPanel {
            return appCount >= 1 ? .panelScopedAutoSwitch : nil
        }
        return appCount == 1 ? .singleWindowAutoSwitch : nil
    }
}
