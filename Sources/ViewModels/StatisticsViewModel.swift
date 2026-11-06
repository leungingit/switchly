//
//  StatisticsViewModel.swift
//  Switchly
//
//  Drives the statistics panel: granularity, series visibility, the cached
//  aggregation and the baseline picker.
//
//  Aggregation happens here -- not in the view -- and only when something
//  actually changed (a new record, a different granularity, a different
//  baseline). The chart body then only maps numbers to points.
//

import Foundation
import Combine
import SwiftUI

/// Raw per-series values for the chart, in bucket order.
struct StatisticsSeriesValues {
    var previewKeyboard: [Double] = []
    var previewPointer: [Double] = []
    var quickSwitch: [Double] = []
    var workspace: [Double] = []
    var committedKeyboard: [Double] = []
    var committedPointer: [Double] = []

    var all: [Double] {
        previewKeyboard + previewPointer + quickSwitch + workspace + committedKeyboard + committedPointer
    }
}

@MainActor
final class StatisticsViewModel: ObservableObject {
    static let previewKeyboardID = "preview.keyboard"
    static let previewPointerID = "preview.pointer"
    static let quickSwitchID = "quickSwitch"
    static let workspaceID = "workspace"
    static let committedKeyboardID = "committed.keyboard"
    static let committedPointerID = "committed.pointer"

    @Published var granularity: StatisticsGranularity = .day {
        didSet { if oldValue != granularity { needsAggregation = true; refreshIfNeeded() } }
    }

    @Published private(set) var buckets: [StatisticsBucket] = []
    @Published private(set) var bucketLabels: [String] = []
    @Published private(set) var savedSecondsByBucket: [Double] = []
    @Published private(set) var seriesValues = StatisticsSeriesValues()
    @Published private(set) var flows: [EfficiencyFlow] = []
    @Published private(set) var rangeSummary: EfficiencySummary = .empty
    @Published private(set) var todaySummary: EfficiencySummary = .empty
    @Published private(set) var weekSummary: EfficiencySummary = .empty
    @Published private(set) var monthSummary: EfficiencySummary = .empty
    @Published private(set) var allTimeSummary: EfficiencySummary = .empty
    @Published private(set) var allTimeTotals: UsageTotals = .empty
    @Published private(set) var baseline: EfficiencyBaseline = .recommended
    /// The two "confirmed switch" series start hidden (plan section 6.2):
    /// four lines stay readable, and the detail table carries their numbers.
    @Published private(set) var hiddenSeries: Set<String> = [
        StatisticsViewModel.committedKeyboardID,
        StatisticsViewModel.committedPointerID
    ]
    @Published private(set) var didLoad = false

    private let service: UsageStatisticsService
    private let settingsService: SettingsServiceProtocol
    private var settings: AppSettings
    private var snapshot: UsageStatisticsSnapshot = .empty
    private var lastRevision = -1
    private var needsAggregation = true
    private var timer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    private let now: () -> Date
    private let calendar: Calendar

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// `service` defaults to nil so the default-argument expression itself
    /// stays nonisolated; it is resolved on the main actor inside.
    init(service: UsageStatisticsService? = nil,
         settingsService: SettingsServiceProtocol = SettingsService.shared,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.service = service ?? .shared
        self.settingsService = settingsService
        self.calendar = calendar
        self.now = now
        let loaded = settingsService.loadSettings()
        self.settings = loaded
        self.baseline = EfficiencyBaseline.resolved(preset: loaded.efficiencyBaselinePreset,
                                                    custom: loaded.efficiencyBaselineCustom)
    }

    var language: AppLanguage { settings.language }

    var isEnabled: Bool { settings.usageStatisticsEnabled }

    var isEmpty: Bool { allTimeTotals.isEmpty }

    var rangeUnitLabel: String {
        switch granularity {
        case .day: return "days"
        case .week: return "weeks"
        case .month: return "months"
        }
    }

    /// Starts the lightweight revision poll. The panel is short-lived, so this
    /// is only alive while it is on screen; it does no work when nothing changed.
    /// Subscribes to settings changes without starting the revision poll.
    /// Preferences uses this: it needs the picker to stay in sync, not a timer.
    func observeSettingsChanges() {
        guard cancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: .settingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadSettings()
            }
            .store(in: &cancellables)
    }

    func activate() {
        observeSettingsChanges()
        Task { [weak self] in await self?.awaitReady() }
        guard timer == nil else { return }
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshIfNeeded() }
    }

    /// Awaits the first load and recomputes. Exposed so tests (and anything
    /// else that needs a settled first frame) do not have to poll.
    func awaitReady() async {
        await service.awaitReady()
        didLoad = true
        needsAggregation = true
        refreshIfNeeded(force: true)
    }

    func deactivate() {
        timer?.cancel()
        timer = nil
    }

    func refreshIfNeeded(force: Bool = false) {
        guard didLoad else { return }
        let revision = service.revision
        guard force || needsAggregation || revision != lastRevision else { return }
        lastRevision = revision
        needsAggregation = false
        snapshot = service.snapshot()
        recompute()
    }

    private func reloadSettings() {
        settings = settingsService.loadSettings()
        baseline = EfficiencyBaseline.resolved(preset: settings.efficiencyBaselinePreset,
                                               custom: settings.efficiencyBaselineCustom)
        needsAggregation = true
        refreshIfNeeded(force: true)
    }

    // MARK: Aggregation

    private func recompute() {
        let current = now()
        let computed = UsageStatisticsAggregator.buckets(days: snapshot.days,
                                                         granularity: granularity,
                                                         calendar: calendar,
                                                         now: current)
        buckets = computed
        bucketLabels = computed.map { label(for: $0.start) }
        savedSecondsByBucket = EfficiencyMath.savedSeconds(computed, baseline: baseline)

        var values = StatisticsSeriesValues()
        values.previewKeyboard = computed.map { Double($0.totals.previewKeyboard) }
        values.previewPointer = computed.map { Double($0.totals.previewPointer) }
        values.quickSwitch = computed.map { Double($0.totals.quickSwitchCount) }
        values.workspace = computed.map { Double($0.totals.workspaceKeyboard + $0.totals.workspacePointer) }
        values.committedKeyboard = computed.map { Double($0.totals.switchKeyboard) }
        values.committedPointer = computed.map { Double($0.totals.switchPointer) }
        seriesValues = values

        let rangeTotals = UsageTotals(counts: computed.reduce(into: [String: Int]()) { partial, bucket in
            partial.merge(bucket.counts) { $0 + $1 }
        })
        flows = EfficiencyMath.flows(rangeTotals, baseline: baseline)
        rangeSummary = EfficiencyMath.summary(flows, baseline: baseline)

        // Fixed-caliber cards, independent of the selected granularity.
        todaySummary = summary(in: calendar.dateInterval(of: .day, for: current), now: current)
        weekSummary = summary(in: calendar.dateInterval(of: .weekOfYear, for: current), now: current)
        monthSummary = summary(in: calendar.dateInterval(of: .month, for: current), now: current)
        let everything = snapshot.totals()
        allTimeTotals = everything
        allTimeSummary = EfficiencyMath.summary(EfficiencyMath.flows(everything, baseline: baseline), baseline: baseline)
    }

    private func summary(in interval: DateInterval?, now: Date) -> EfficiencySummary {
        let totals = snapshot.totals(in: interval, calendar: calendar)
        return EfficiencyMath.summary(EfficiencyMath.flows(totals, baseline: baseline), baseline: baseline)
    }

    private func label(for date: Date) -> String {
        switch granularity {
        case .day, .week: return Self.dayLabelFormatter.string(from: date)
        case .month: return Self.monthLabelFormatter.string(from: date)
        }
    }

    // MARK: Legend

    func isVisible(_ id: String) -> Bool { !hiddenSeries.contains(id) }

    func toggleSeries(_ id: String) {
        if hiddenSeries.contains(id) {
            hiddenSeries.remove(id)
        } else {
            // Keep at least one series so the chart cannot go blank by accident.
            guard visibleSeriesCount > 1 else { return }
            hiddenSeries.insert(id)
        }
    }

    var visibleSeriesCount: Int {
        6 - hiddenSeries.count
    }

    // MARK: Baseline

    func setPreset(_ preset: EfficiencyBaselinePreset) {
        var updated = settings
        updated.efficiencyBaselinePreset = preset
        if preset == .custom, updated.efficiencyBaselineCustom == nil {
            updated.efficiencyBaselineCustom = baseline.values
        }
        persist(updated, baselinePreset: preset, custom: updated.efficiencyBaselineCustom)
    }

    func setCustomSeconds(_ seconds: Double, feature: EfficiencyFeature, keyboard: Bool) {
        var values = settings.efficiencyBaselineCustom ?? baseline.values
        switch (feature, keyboard) {
        case (.preview, true): values.previewKeyboardSeconds = seconds
        case (.preview, false): values.previewMouseSeconds = seconds
        case (.quickSwitch, true): values.quickSwitchKeyboardSeconds = seconds
        case (.quickSwitch, false): values.quickSwitchMouseSeconds = seconds
        case (.workspace, true): values.workspaceKeyboardSeconds = seconds
        case (.workspace, false): values.workspaceMouseSeconds = seconds
        }
        var updated = settings
        updated.efficiencyBaselineCustom = values
        updated.efficiencyBaselinePreset = .custom
        persist(updated, baselinePreset: .custom, custom: values)
    }

    func restoreRecommendedBaseline() {
        var updated = settings
        updated.efficiencyBaselinePreset = .standard
        updated.efficiencyBaselineCustom = nil
        persist(updated, baselinePreset: .standard, custom: nil)
    }

    /// Writes through immediately: the whole point of the in-panel picker is
    /// to look at the numbers for a few days and then decide.
    private func persist(_ updated: AppSettings,
                         baselinePreset: EfficiencyBaselinePreset,
                         custom: EfficiencyBaselineValues?) {
        do {
            try settingsService.saveSettings(updated)
        } catch {
            AppLogger.error("Failed to save efficiency baseline. error=\(error)")
        }
        settings = updated
        baseline = EfficiencyBaseline.resolved(preset: baselinePreset, custom: custom)
        needsAggregation = true
        refreshIfNeeded(force: true)
    }

    // MARK: Actions

    func clear() {
        service.clear()
        needsAggregation = true
        refreshIfNeeded(force: true)
        Task { await service.flush() }
    }
}
