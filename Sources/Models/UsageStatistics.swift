//
//  UsageStatistics.swift
//  Switchly
//
//  Event vocabulary, aggregation and formatting for the statistics panel.
//  See docs/plan/2026-09-29-statistics-panel.md (v3).
//
//  Everything here is a pure function over value types: it can be exercised
//  headless (no window server), and the panel's chart only has to map
//  precomputed series to points -- it never computes counts itself.
//

import Foundation

// MARK: - Event vocabulary

/// What happened. One case per feature the panel reports.
enum UsageEventKind: String, Codable, CaseIterable {
    /// The preview panel was put on screen (keyboard or pointer).
    case previewPresented
    /// A window was confirmed from inside the preview panel -- the anchor the
    /// efficiency comparison is built on.
    case previewSwitchCommitted
    /// A window was switched to without ever showing the panel.
    case quickSwitch
    /// The workspace bar was summoned.
    case workspacePresented
}

/// Who called it. The input mode is derived, never stored twice.
enum UsageEventSource: String, Codable, CaseIterable {
    // Keyboard
    case globalShortcut
    case appShortcut
    case currentAppWindowShortcut
    case workspaceShortcut
    case panelKeyboard
    // Pointer
    case statusMenu
    case statusPopover
    case panelClick
    /// The Dock hover preview: shown on hover, confirmed by clicking a
    /// window inside it.
    case dockHover
    /// The pointer hotspot: the pointer rested against a screen edge.
    case edgeHotspot
    /// The shake gesture: the pointer was wiggled back and forth quickly.
    case pointerShake
    // Reserved / catch-all
    case unknown

    var inputMode: UsageInputMode {
        switch self {
        case .globalShortcut, .appShortcut, .currentAppWindowShortcut,
             .workspaceShortcut, .panelKeyboard:
            return .keyboard
        case .statusMenu, .statusPopover, .panelClick, .dockHover,
             .edgeHotspot, .pointerShake:
            return .pointer
        case .unknown:
            return .unclassified
        }
    }
}

enum UsageInputMode: String, Codable, CaseIterable {
    case keyboard
    case pointer
    /// Only reachable through the reserved sources; must stay empty in
    /// practice, and it never enters the efficiency ratio.
    case unclassified
}

/// Storage key for one counter: "<kind>:<source>".
enum UsageMetricKey {
    static func key(_ kind: UsageEventKind, _ source: UsageEventSource) -> String {
        "\(kind.rawValue):\(source.rawValue)"
    }

    static func parse(_ key: String) -> (kind: UsageEventKind, source: UsageEventSource)? {
        guard let separator = key.firstIndex(of: ":") else { return nil }
        let kindRaw = String(key[key.startIndex..<separator])
        let sourceRaw = String(key[key.index(after: separator)...])
        guard let kind = UsageEventKind(rawValue: kindRaw),
              let source = UsageEventSource(rawValue: sourceRaw) else { return nil }
        return (kind, source)
    }
}

// MARK: - Day keys

/// Local-calendar day keys ("yyyy-MM-dd").
///
/// Built from `Calendar` components rather than a `DateFormatter`: the record
/// path runs inside shortcut callbacks and a formatter is orders of magnitude
/// more expensive than the dictionary increment it accompanies.
enum UsageDayKey {
    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(for key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }
}

// MARK: - Persisted shape

/// Whole-file model. `days[<yyyy-MM-dd>][<kind>:<source>] = count`.
struct UsageStatisticsFile: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var days: [String: [String: Int]]

    init(schemaVersion: Int = UsageStatisticsFile.currentSchemaVersion,
         days: [String: [String: Int]] = [:]) {
        self.schemaVersion = schemaVersion
        self.days = days
    }

    /// A file written by a newer build is treated as unreadable so an older
    /// build cannot silently overwrite data it does not understand.
    var isReadable: Bool { schemaVersion <= Self.currentSchemaVersion }
}

/// Immutable copy handed to readers. Taken by value so a reader can do slow
/// work off the main actor without touching service state.
struct UsageStatisticsSnapshot: Equatable {
    var days: [String: [String: Int]]

    init(days: [String: [String: Int]] = [:]) {
        self.days = days
    }

    static let empty = UsageStatisticsSnapshot()

    var isEmpty: Bool { totals().isEmpty }

    func totals(in interval: DateInterval? = nil, calendar: Calendar = .current) -> UsageTotals {
        guard let interval else {
            var merged: [String: Int] = [:]
            for counts in days.values { merged.merge(counts) { $0 + $1 } }
            return UsageTotals(counts: merged)
        }
        var merged: [String: Int] = [:]
        for (key, counts) in days {
            guard let date = UsageDayKey.date(for: key, calendar: calendar),
                  interval.contains(date) else { continue }
            merged.merge(counts) { $0 + $1 }
        }
        return UsageTotals(counts: merged)
    }
}

/// Aggregated counts, still keyed by metric so any slice stays one lookup away.
struct UsageTotals: Equatable {
    var counts: [String: Int]

    init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    static let empty = UsageTotals()

    var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }

    func count(kind: UsageEventKind, source: UsageEventSource) -> Int {
        counts[UsageMetricKey.key(kind, source)] ?? 0
    }

    func count(kind: UsageEventKind, inputMode: UsageInputMode) -> Int {
        counts.reduce(0) { partial, entry in
            guard let parsed = UsageMetricKey.parse(entry.key),
                  parsed.kind == kind,
                  parsed.source.inputMode == inputMode else { return partial }
            return partial + entry.value
        }
    }

    func count(kind: UsageEventKind) -> Int {
        counts.reduce(0) { partial, entry in
            guard let parsed = UsageMetricKey.parse(entry.key), parsed.kind == kind else { return partial }
            return partial + entry.value
        }
    }

    // Chart series (see the plan's section 6.2).
    var previewKeyboard: Int { count(kind: .previewPresented, inputMode: .keyboard) }
    var previewPointer: Int { count(kind: .previewPresented, inputMode: .pointer) }
    var switchKeyboard: Int { count(kind: .previewSwitchCommitted, source: .panelKeyboard) }
    /// Pointer confirmations: a click on a card in the preview panel, or a
    /// click on a window in the Dock hover preview.
    var switchPointer: Int {
        count(kind: .previewSwitchCommitted, source: .panelClick)
            + count(kind: .previewSwitchCommitted, source: .dockHover)
    }
    var quickSwitchCount: Int { count(kind: .quickSwitch) }
    var workspaceKeyboard: Int { count(kind: .workspacePresented, inputMode: .keyboard) }
    var workspacePointer: Int { count(kind: .workspacePresented, inputMode: .pointer) }

    /// Sources that reached neither side (must stay 0; shown, never counted).
    var unclassified: Int {
        count(kind: .previewPresented, inputMode: .unclassified)
            + count(kind: .workspacePresented, inputMode: .unclassified)
            + count(kind: .quickSwitch, inputMode: .unclassified)
    }

    /// Completed flows, which is what the efficiency card reports.
    var keyboardFlowCount: Int { switchKeyboard + quickSwitchCount + workspaceKeyboard }
    var pointerFlowCount: Int { switchPointer + workspacePointer }
    var flowCount: Int { keyboardFlowCount + pointerFlowCount }
}

// MARK: - Buckets

enum StatisticsGranularity: String, Codable, CaseIterable, Hashable {
    case day
    case week
    case month

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    var defaultRange: Int {
        switch self {
        case .day: return 30
        case .week: return 12
        case .month: return 12
        }
    }
}

struct StatisticsBucket: Identifiable, Equatable {
    let start: Date
    let end: Date
    let counts: [String: Int]

    var id: Date { start }

    var totals: UsageTotals { UsageTotals(counts: counts) }

    var isEmpty: Bool { counts.isEmpty }
}

enum UsageStatisticsAggregator {
    /// Buckets over `range` units ending with the one that contains `now`.
    ///
    /// Empty buckets are generated too: iterating "days that have data" would
    /// join 9/1 and 9/9 with a straight line and lie about the gap.
    static func buckets(days: [String: [String: Int]],
                        granularity: StatisticsGranularity,
                        range: Int? = nil,
                        calendar: Calendar = .current,
                        now: Date) -> [StatisticsBucket] {
        let bucketCount = max(0, range ?? granularity.defaultRange)
        guard bucketCount > 0 else { return [] }
        let component = granularity.component
        guard let lastStart = calendar.dateInterval(of: component, for: now)?.start else { return [] }

        // Bucket the raw day keys once; each bucket is then a cheap day walk.
        var byDay: [Date: [String: Int]] = [:]
        for (key, counts) in days {
            guard let date = UsageDayKey.date(for: key, calendar: calendar) else { continue }
            byDay[calendar.startOfDay(for: date), default: [:]].merge(counts) { $0 + $1 }
        }

        var result: [StatisticsBucket] = []
        result.reserveCapacity(bucketCount)
        for offset in stride(from: bucketCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: component, value: -offset, to: lastStart),
                  let end = calendar.date(byAdding: component, value: 1, to: start) else { continue }
            var counts: [String: Int] = [:]
            var cursor = start
            while cursor < end {
                if let dayCounts = byDay[cursor] {
                    counts.merge(dayCounts) { $0 + $1 }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            result.append(StatisticsBucket(start: start, end: end, counts: counts))
        }
        return result
    }

    /// Drops days older than the retention window. Runs on load only, so the
    /// write path never pays for it.
    static func prune(days: [String: [String: Int]],
                      keepingDays: Int,
                      calendar: Calendar = .current,
                      now: Date) -> [String: [String: Int]] {
        guard keepingDays > 0 else { return [:] }
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(keepingDays - 1), to: today) else { return days }
        var kept: [String: [String: Int]] = [:]
        for (key, counts) in days {
            guard let date = UsageDayKey.date(for: key, calendar: calendar),
                  date >= cutoff else { continue }
            kept[key] = counts
        }
        return kept
    }

    /// Convenience for summary cards: totals across a bucket list.
    static func total(_ buckets: [StatisticsBucket],
                      kind: UsageEventKind,
                      source: UsageEventSource? = nil) -> Int {
        buckets.reduce(0) { partial, bucket in
            let totals = bucket.totals
            if let source {
                return partial + totals.count(kind: kind, source: source)
            }
            return partial + totals.count(kind: kind)
        }
    }
}

// MARK: - Formatting

enum UsageStatisticsFormatter {
    enum DurationUnit: String, Equatable {
        case seconds
        case minutes
        case hours
    }

    struct DurationParts: Equatable {
        let unit: DurationUnit
        let primary: Int
        let secondary: Int
    }

    /// < 60 s -> seconds; < 60 min -> minutes + seconds; otherwise hours + minutes.
    static func duration(seconds: Double) -> DurationParts {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(safe.rounded())
        if total < 60 {
            return DurationParts(unit: .seconds, primary: total, secondary: 0)
        }
        if total < 3600 {
            return DurationParts(unit: .minutes, primary: total / 60, secondary: total % 60)
        }
        return DurationParts(unit: .hours, primary: total / 3600, secondary: (total % 3600) / 60)
    }

    /// One decimal place, but only when it adds information.
    static func multiple(_ value: Double) -> String {
        guard value.isFinite else { return "1.0" }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return String(format: "%.0f%%", value * 100)
    }
}
