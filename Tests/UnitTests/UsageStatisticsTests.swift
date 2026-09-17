//
//  UsageStatisticsTests.swift
//  SwitchlyTests
//
//  Storage, aggregation, efficiency and the "no UI blocking" guarantees.
//  Everything here runs headless.
//

import XCTest
@testable import Switchly

// MARK: - Test doubles

/// Counts writes and records the values it was handed. Thread-safe because
/// writes land on the service's io queue.
final class RecordingStatisticsWriter: UsageStatisticsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _loadCount = 0
    private var _writeCount = 0
    private var _written: [UsageStatisticsFile] = []
    private var _concurrentWrites = 0
    private var _maxConcurrentWrites = 0

    var storedFile: UsageStatisticsFile?
    var loadError: Error?
    var writeError: Error?
    var writeDelay: TimeInterval = 0

    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return _loadCount }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }
    var written: [UsageStatisticsFile] { lock.lock(); defer { lock.unlock() }; return _written }
    var maxConcurrentWrites: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrentWrites }

    func load() throws -> UsageStatisticsFile? {
        lock.lock(); _loadCount += 1; lock.unlock()
        if let loadError { throw loadError }
        return storedFile
    }

    func write(_ file: UsageStatisticsFile) throws {
        lock.lock()
        _writeCount += 1
        let concurrent = _concurrentWrites + 1
        _concurrentWrites = concurrent
        _maxConcurrentWrites = max(_maxConcurrentWrites, concurrent)
        lock.unlock()

        if writeDelay > 0 { Thread.sleep(forTimeInterval: writeDelay) }

        lock.lock()
        _concurrentWrites -= 1
        let error = writeError
        lock.unlock()

        if let error { throw error }
        lock.lock(); _written.append(file); lock.unlock()
    }
}

enum TestError: Error {
    case intended
}

// MARK: - Storage and recording

@MainActor
final class UsageStatisticsTests: XCTestCase {

    private func makeCalendar(_ timeZone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 12, _ minute: Int = 0, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func makeService(writer: RecordingStatisticsWriter,
                             calendar: Calendar,
                             now: Date,
                             coalescingDelay: TimeInterval = 0.05,
                             maxDelay: TimeInterval = 0.1) -> UsageStatisticsService {
        UsageStatisticsService(writer: writer,
                               calendar: calendar,
                               now: { now },
                               ioQueue: DispatchQueue(label: "test.usage.statistics.io"),
                               coalescingDelay: coalescingDelay,
                               maxDelay: maxDelay)
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-statistics-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".json")
    }

    // MARK: 1-2 record / accumulate / day splitting

    func testRecordAccumulatesOnTheSameDay() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, 10, 0, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now)
        await service.awaitReady()

        service.record(.previewPresented, source: .globalShortcut, at: now)
        service.record(.previewPresented, source: .globalShortcut, at: now)
        service.record(.quickSwitch, source: .appShortcut, at: now)

        let days = service.snapshot().days
        XCTAssertEqual(days["2026-09-29"]?["previewPresented:globalShortcut"], 2)
        XCTAssertEqual(days["2026-09-29"]?["quickSwitch:appShortcut"], 1)
        XCTAssertEqual(days.count, 1)
    }

    func testRecordsLandInSeparateDayBuckets() async {
        let calendar = makeCalendar()
        let n1 = date(2026, 9, 29, 23, 59, calendar: calendar)
        let n2 = date(2026, 9, 30, 0, 1, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: n1)
        await service.awaitReady()

        service.record(.previewPresented, source: .globalShortcut, at: n1)
        service.record(.previewPresented, source: .globalShortcut, at: n2)

        let days = service.snapshot().days
        XCTAssertEqual(days["2026-09-29"]?["previewPresented:globalShortcut"], 1)
        XCTAssertEqual(days["2026-09-30"]?["previewPresented:globalShortcut"], 1)
    }

    /// The Preferences switch: no new records, existing data untouched.
    func testDisabledServiceDoesNotRecord() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now)
        await service.awaitReady()

        service.record(.quickSwitch, source: .appShortcut, at: now)
        service.isEnabled = false
        service.record(.quickSwitch, source: .appShortcut, at: now)

        XCTAssertEqual(service.snapshot().totals().quickSwitchCount, 1)
        service.isEnabled = true
        service.record(.quickSwitch, source: .appShortcut, at: now)
        XCTAssertEqual(service.snapshot().totals().quickSwitchCount, 2)
    }

    func testClearEmptiesMemoryAndPersists() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now)
        await service.awaitReady()

        service.record(.workspacePresented, source: .workspaceShortcut, at: now)
        service.clear()
        await service.flush()

        XCTAssertTrue(service.snapshot().isEmpty)
        XCTAssertEqual(writer.written.last?.days.isEmpty, true)
    }

    func testQuickSwitchAndConfirmedSwitchStayApart() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now)
        await service.awaitReady()

        service.record(.quickSwitch, source: .appShortcut, at: now)
        service.record(.previewSwitchCommitted, source: .panelKeyboard, at: now)

        let totals = service.snapshot().totals()
        XCTAssertEqual(totals.quickSwitchCount, 1)
        XCTAssertEqual(totals.switchKeyboard, 1)
        XCTAssertEqual(totals.switchPointer, 0)
        XCTAssertEqual(totals.keyboardFlowCount, 2)
    }

    // MARK: 3 aggregator

    func testBucketsFillEmptyDaysWithZero() {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let days = [
            "2026-09-01": ["previewPresented:globalShortcut": 4],
            "2026-09-29": ["previewPresented:globalShortcut": 7]
        ]
        let buckets = UsageStatisticsAggregator.buckets(days: days,
                                                        granularity: .day,
                                                        range: 30,
                                                        calendar: calendar,
                                                        now: now)
        XCTAssertEqual(buckets.count, 30)
        XCTAssertEqual(buckets.first?.start, calendar.startOfDay(for: date(2026, 8, 31, calendar: calendar)))
        XCTAssertEqual(buckets.last?.start, calendar.startOfDay(for: now))
        XCTAssertEqual(buckets[1].counts["previewPresented:globalShortcut"], 4)
        XCTAssertEqual(buckets[14].counts["previewPresented:globalShortcut"], nil)
        XCTAssertEqual(buckets.last?.counts["previewPresented:globalShortcut"], 7)
    }

    func testBucketStartsAcrossMonthYearAndLeapBoundaries() {
        let calendar = makeCalendar()
        // Leap day + a month boundary.
        let now = date(2028, 3, 1, 9, 0, calendar: calendar)
        let buckets = UsageStatisticsAggregator.buckets(days: [:],
                                                        granularity: .month,
                                                        range: 3,
                                                        calendar: calendar,
                                                        now: now)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(UsageDayKey.key(for: buckets[0].start, calendar: calendar), "2028-01-01")
        XCTAssertEqual(UsageDayKey.key(for: buckets[1].start, calendar: calendar), "2028-02-01")
        XCTAssertEqual(UsageDayKey.key(for: buckets[2].start, calendar: calendar), "2028-03-01")

        // 12 -> 1 across a year boundary.
        let newYear = date(2027, 1, 4, 9, 0, calendar: calendar)
        let weekBuckets = UsageStatisticsAggregator.buckets(days: [:],
                                                            granularity: .week,
                                                            range: 2,
                                                            calendar: calendar,
                                                            now: newYear)
        XCTAssertEqual(weekBuckets.count, 2)
        XCTAssertEqual(UsageDayKey.key(for: weekBuckets[0].start, calendar: calendar), "2026-12-28")
        XCTAssertEqual(UsageDayKey.key(for: weekBuckets[1].start, calendar: calendar), "2027-01-04")
    }

    func testBucketStartsSurviveDaylightSavingChange() {
        // US DST starts 2026-03-08: iterating by "day +1" (not +86400) must not
        // skip or duplicate a day.
        let calendar = makeCalendar("America/New_York")
        let now = date(2026, 3, 10, 12, 0, calendar: calendar)
        let days = ["2026-03-07": ["previewPresented:globalShortcut": 1],
                    "2026-03-08": ["previewPresented:globalShortcut": 2],
                    "2026-03-09": ["previewPresented:globalShortcut": 3]]
        let buckets = UsageStatisticsAggregator.buckets(days: days,
                                                        granularity: .day,
                                                        range: 4,
                                                        calendar: calendar,
                                                        now: now)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(UsageDayKey.key(for: buckets[0].start, calendar: calendar), "2026-03-07")
        XCTAssertEqual(UsageDayKey.key(for: buckets[3].start, calendar: calendar), "2026-03-10")
        let totals = buckets.map { $0.counts["previewPresented:globalShortcut"] ?? 0 }
        XCTAssertEqual(totals, [1, 2, 3, 0])
    }

    func testPruneKeepsRetentionWindow() {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let days = [
            "2026-09-29": ["previewPresented:globalShortcut": 1],
            "2025-08-26": ["previewPresented:globalShortcut": 9]   // exactly 399 days earlier
        ]
        // 400 days of retention includes a day that is 399 days older than today.
        let kept = UsageStatisticsAggregator.prune(days: days, keepingDays: 400, calendar: calendar, now: now)
        XCTAssertEqual(kept.count, 2)
        XCTAssertNotNil(kept["2026-09-29"])
        XCTAssertNotNil(kept["2025-08-26"])

        // One day less drops it: the window counts today as day 1.
        let pruned = UsageStatisticsAggregator.prune(days: days, keepingDays: 399, calendar: calendar, now: now)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertNotNil(pruned["2026-09-29"])
        XCTAssertNil(pruned["2025-08-26"])
    }

    func testSnapshotTotalsRespectInterval() {
        let calendar = makeCalendar()
        let days = [
            "2026-08-31": ["previewPresented:globalShortcut": 1],
            "2026-09-01": ["previewPresented:globalShortcut": 2],
            "2026-09-29": ["previewPresented:globalShortcut": 4]
        ]
        let snapshot = UsageStatisticsSnapshot(days: days)
        // Midnight-to-midnight, exactly like Calendar.dateInterval(of:for:).
        let september = DateInterval(start: date(2026, 9, 1, 0, 0, calendar: calendar),
                                    end: date(2026, 10, 1, 0, 0, calendar: calendar))
        XCTAssertEqual(snapshot.totals(in: september, calendar: calendar).previewKeyboard, 6)
        XCTAssertEqual(snapshot.totals(calendar: calendar).previewKeyboard, 7)
    }

    // MARK: 4 input modes and attribution

    func testInputModeMappingIsExhaustiveAndDisjoint() {
        var keyboard = 0
        var pointer = 0
        var unclassified = 0
        for source in UsageEventSource.allCases {
            switch source.inputMode {
            case .keyboard: keyboard += 1
            case .pointer: pointer += 1
            case .unclassified: unclassified += 1
            }
        }
        XCTAssertEqual(keyboard + pointer + unclassified, UsageEventSource.allCases.count)
        XCTAssertEqual(source(.globalShortcut), .keyboard)
        XCTAssertEqual(source(.appShortcut), .keyboard)
        XCTAssertEqual(source(.currentAppWindowShortcut), .keyboard)
        XCTAssertEqual(source(.workspaceShortcut), .keyboard)
        XCTAssertEqual(source(.panelKeyboard), .keyboard)
        XCTAssertEqual(source(.statusMenu), .pointer)
        XCTAssertEqual(source(.statusPopover), .pointer)
        XCTAssertEqual(source(.panelClick), .pointer)
        XCTAssertEqual(source(.dockHover), .pointer)
        XCTAssertEqual(source(.unknown), .unclassified)
    }

    private func source(_ source: UsageEventSource) -> UsageInputMode { source.inputMode }

    func testMetricKeyRoundTrip() {
        for kind in UsageEventKind.allCases {
            for source in UsageEventSource.allCases {
                let key = UsageMetricKey.key(kind, source)
                let parsed = UsageMetricKey.parse(key)
                XCTAssertEqual(parsed?.kind, kind)
                XCTAssertEqual(parsed?.source, source)
            }
        }
        XCTAssertNil(UsageMetricKey.parse("nonsense"))
        XCTAssertNil(UsageMetricKey.parse("previewPresented:notASource"))
    }

    func testQuickSwitchAttributionIsMutuallyExclusive() {
        XCTAssertEqual(QuickSwitchAttribution.scenario(appCount: 1, autoSwitchIfSingle: true,
                                                       appWindowCount: 1, viaPanel: false,
                                                       isCurrentAppWindowShortcut: false),
                       .singleWindowAutoSwitch)
        XCTAssertEqual(QuickSwitchAttribution.scenario(appCount: 2, autoSwitchIfSingle: true,
                                                       appWindowCount: 1, viaPanel: true,
                                                       isCurrentAppWindowShortcut: false),
                       .panelScopedAutoSwitch)
        XCTAssertEqual(QuickSwitchAttribution.scenario(appCount: 1, autoSwitchIfSingle: false,
                                                       appWindowCount: 1, viaPanel: false,
                                                       isCurrentAppWindowShortcut: true),
                       .currentAppWindowRotation)
        // No switch happened.
        XCTAssertNil(QuickSwitchAttribution.scenario(appCount: 1, autoSwitchIfSingle: true,
                                                     appWindowCount: 2, viaPanel: false,
                                                     isCurrentAppWindowShortcut: false))
        XCTAssertNil(QuickSwitchAttribution.scenario(appCount: 1, autoSwitchIfSingle: false,
                                                     appWindowCount: 1, viaPanel: false,
                                                     isCurrentAppWindowShortcut: false))
        XCTAssertEqual(QuickSwitchAttribution.source(for: .singleWindowAutoSwitch), .appShortcut)
        XCTAssertEqual(QuickSwitchAttribution.source(for: .panelScopedAutoSwitch), .appShortcut)
        XCTAssertEqual(QuickSwitchAttribution.source(for: .currentAppWindowRotation), .currentAppWindowShortcut)
    }

    // MARK: 5 efficiency

    func testEfficiencyWithNoKeyboardActivityIsNeutral() {
        let totals = UsageTotals(counts: ["previewSwitchCommitted:panelClick": 3])
        let flows = EfficiencyMath.flows(totals, baseline: .recommended)
        let summary = EfficiencyMath.summary(flows, baseline: .recommended)
        XCTAssertEqual(summary.savedSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.multiple, 1, accuracy: 0.0001)
        XCTAssertTrue(summary.hasActivity)
    }

    func testEfficiencyWithOnlyKeyboardActivityEqualsRatio() {
        let totals = UsageTotals(counts: ["previewSwitchCommitted:panelKeyboard": 10])
        let summary = EfficiencyMath.summary(EfficiencyMath.flows(totals, baseline: .recommended),
                                             baseline: .recommended)
        XCTAssertEqual(summary.savedSeconds, 95, accuracy: 0.0001)
        XCTAssertEqual(summary.multiple, 12.0 / 2.5, accuracy: 0.0001)
    }

    func testEfficiencyDivideByZeroIsGuarded() {
        XCTAssertEqual(EfficiencyMath.multiple(baselineSeconds: 0, actualSeconds: 0), 1)
        XCTAssertEqual(EfficiencyMath.multiple(baselineSeconds: 120, actualSeconds: 0), 1)
        XCTAssertEqual(EfficiencyMath.multiple(baselineSeconds: .nan, actualSeconds: 10), 1)
    }

    func testMoreMouseActionsDiluteTheMultiple() {
        let base: [String: Int] = ["previewSwitchCommitted:panelKeyboard": 50]
        var previous = Double.greatestFiniteMagnitude
        for pointerCount in [0, 5, 20, 50, 100] {
            var counts = base
            counts["previewSwitchCommitted:panelClick"] = pointerCount
            let summary = EfficiencyMath.summary(EfficiencyMath.flows(UsageTotals(counts: counts),
                                                                      baseline: .recommended),
                                                 baseline: .recommended)
            XCTAssertGreaterThanOrEqual(summary.multiple, 1)
            XCTAssertLessThanOrEqual(summary.multiple, previous)
            previous = summary.multiple
        }
    }

    func testNegativePerUseSavingIsClampedToZero() {
        // A mis-configured baseline (shortcut slower than mouse) must never
        // surface as a negative saving.
        var values = EfficiencyBaselineValues.standard
        values.previewKeyboardSeconds = 20
        values.previewMouseSeconds = 5
        let baseline = EfficiencyBaseline(preset: .custom, values: values)
        let summary = EfficiencyMath.summary(EfficiencyMath.flows(UsageTotals(counts: ["previewSwitchCommitted:panelKeyboard": 10]),
                                                                  baseline: baseline),
                                             baseline: baseline)
        XCTAssertEqual(summary.savedSeconds, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(summary.multiple, 1)
    }

    func testBaselineSanitizationFallsBackWhenUnusable() {
        var broken = EfficiencyBaselineValues.standard
        broken.previewKeyboardSeconds = -3
        XCTAssertFalse(broken.isUsable)
        XCTAssertEqual(EfficiencyBaseline.resolved(preset: .custom, custom: broken).preset, .standard)
        XCTAssertEqual(EfficiencyBaseline.resolved(preset: .custom, custom: nil).preset, .standard)
        XCTAssertEqual(EfficiencyBaseline.resolved(preset: .conservative, custom: nil).values,
                       EfficiencyBaselineValues.conservative)

        var tooSlow = EfficiencyBaselineValues.standard
        tooSlow.quickSwitchMouseSeconds = 600
        XCTAssertFalse(tooSlow.isUsable)
        XCTAssertEqual(EfficiencyBaseline.resolved(preset: .custom, custom: tooSlow).values,
                       EfficiencyBaselineValues.standard)
    }

    func testDurationFormattingBoundaries() {
        XCTAssertEqual(UsageStatisticsFormatter.duration(seconds: 0),
                       .init(unit: .seconds, primary: 0, secondary: 0))
        XCTAssertEqual(UsageStatisticsFormatter.duration(seconds: 59.9),
                       .init(unit: .minutes, primary: 1, secondary: 0))
        XCTAssertEqual(UsageStatisticsFormatter.duration(seconds: 60),
                       .init(unit: .minutes, primary: 1, secondary: 0))
        XCTAssertEqual(UsageStatisticsFormatter.duration(seconds: 3594),
                       .init(unit: .minutes, primary: 59, secondary: 54))
        XCTAssertEqual(UsageStatisticsFormatter.duration(seconds: 3600),
                       .init(unit: .hours, primary: 1, secondary: 0))
        XCTAssertEqual(UsageStatisticsFormatter.duration(seconds: -5),
                       .init(unit: .seconds, primary: 0, secondary: 0))
    }

    /// The arithmetic published in the plan's appendix C, asserted here so the
    /// document and the implementation cannot drift apart.
    func testAppendixCArithmetic() {
        let counts = [
            "previewSwitchCommitted:panelKeyboard": 118,
            "previewSwitchCommitted:panelClick": 9,
            "quickSwitch:appShortcut": 64,
            "workspacePresented:workspaceShortcut": 13
        ]
        let summary = EfficiencyMath.summary(EfficiencyMath.flows(UsageTotals(counts: counts),
                                                                  baseline: .recommended),
                                             baseline: .recommended)
        XCTAssertEqual(summary.savedSeconds, 1666, accuracy: 0.5)
        XCTAssertEqual(summary.baselineSeconds, 2114, accuracy: 0.5)
        XCTAssertEqual(summary.actualSeconds, 448, accuracy: 0.5)
        XCTAssertEqual(summary.multiple, 4.7, accuracy: 0.05)
        XCTAssertEqual(summary.keyboardCount, 195)
        XCTAssertEqual(summary.pointerCount, 9)
        XCTAssertEqual(UsageStatisticsFormatter.percent(summary.keyboardShare), "96%")
    }

    // MARK: 6 chart math

    func testYTicksHandleZeroAndNiceSteps() {
        XCTAssertEqual(StatisticsChartMath.yTicks(maxValue: 0), [0, 1])
        XCTAssertEqual(StatisticsChartMath.yTicks(maxValue: -3), [0, 1])
        let ticks = StatisticsChartMath.yTicks(maxValue: 37)
        XCTAssertEqual(ticks, [0, 10, 20, 30, 40])
        XCTAssertEqual(StatisticsChartMath.niceStep(9.25), 10)
        XCTAssertEqual(StatisticsChartMath.niceStep(0.42), 0.5)
        XCTAssertEqual(StatisticsChartMath.niceStep(0), 1)
    }

    func testReadableTicksDropLabelsThatWouldCollide() {
        // The savings chart's plot is ~18 pt tall: four 9 pt labels cannot
        // fit, so only the ones >= 11 pt apart survive. The axis maximum is
        // always kept (it anchors the scale).
        XCTAssertEqual(StatisticsChartMath.readableTicks(ticks: [0, 60, 120, 180],
                                                         axisMax: 180,
                                                         plotHeight: 18),
                       [60, 180])
        // A tall plot keeps every label.
        XCTAssertEqual(StatisticsChartMath.readableTicks(ticks: [0, 5, 10],
                                                         axisMax: 10,
                                                         plotHeight: 106),
                       [0, 5, 10])
        // A flat-zero series still labels both ticks.
        XCTAssertEqual(StatisticsChartMath.readableTicks(ticks: [0, 1],
                                                         axisMax: 1,
                                                         plotHeight: 18),
                       [0, 1])
        // Degenerate inputs pass through unchanged.
        XCTAssertEqual(StatisticsChartMath.readableTicks(ticks: [], axisMax: 10, plotHeight: 100), [])
        XCTAssertEqual(StatisticsChartMath.readableTicks(ticks: [0, 1], axisMax: 1, plotHeight: 0), [0, 1])
    }

    func testChartGeometryStaysInsideThePlot() {
        let size = CGSize(width: 300, height: 150)
        let insets = StatisticsChartInsets.standard
        let plot = StatisticsChartMath.plotRect(size: size, insets: insets)
        let points = StatisticsChartMath.points(values: [0, 5, 10, 2],
                                                size: size,
                                                axisMax: 10,
                                                insets: insets)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.first!.x, plot.minX, accuracy: 0.001)
        XCTAssertEqual(points.last!.x, plot.maxX, accuracy: 0.001)
        XCTAssertEqual(points.first!.y, plot.maxY, accuracy: 0.001)
        XCTAssertEqual(points[2].y, plot.minY, accuracy: 0.001)
        for point in points {
            XCTAssertTrue(plot.insetBy(dx: -0.5, dy: -0.5).contains(point))
        }

        let bars = StatisticsChartMath.bars(values: [0, 4, 8], size: size, axisMax: 8, insets: insets)
        XCTAssertEqual(bars.count, 3)
        for bar in bars {
            XCTAssertGreaterThanOrEqual(bar.minX, plot.minX - 0.001)
            XCTAssertLessThanOrEqual(bar.maxX, plot.maxX + 0.001)
            XCTAssertLessThanOrEqual(bar.maxY, plot.maxY + 0.001)
        }
        XCTAssertEqual(bars[1].height, plot.height / 2, accuracy: 0.5)
    }

    func testLabelStrideAndFirstLastLabels() {
        XCTAssertEqual(StatisticsChartMath.labelStride(bucketCount: 30, plotWidth: 600, labelWidth: 34), 2)
        XCTAssertEqual(StatisticsChartMath.labelStride(bucketCount: 12, plotWidth: 600, labelWidth: 34), 1)
        XCTAssertEqual(StatisticsChartMath.labelStride(bucketCount: 1, plotWidth: 600, labelWidth: 34), 1)
        let indices = StatisticsChartMath.labelIndices(bucketCount: 30, stride: 6)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 29)
        XCTAssertTrue(indices.allSatisfy { $0 >= 0 && $0 < 30 })
    }

    func testHoverIndexAndDataXMatchTheDrawnGeometry() {
        let linePlot = CGRect(x: 50, y: 0, width: 400, height: 100)
        // Lines: the nearest of the 5 plotted points at 50/150/250/350/450.
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 130, plot: linePlot, count: 5, style: .line), 1)
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 310, plot: linePlot, count: 5, style: .line), 3)
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 10, plot: linePlot, count: 5, style: .line), 0)
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 900, plot: linePlot, count: 5, style: .line), 4)
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 0, plot: linePlot, count: 1, style: .line), 0)
        XCTAssertEqual(StatisticsChartMath.dataX(index: 2, plot: linePlot, count: 5, style: .line), 250)
        XCTAssertEqual(StatisticsChartMath.dataX(index: 0, plot: linePlot, count: 1, style: .line),
                       linePlot.midX)

        let barPlot = CGRect(x: 0, y: 0, width: 400, height: 100)
        // Bars: the slot the cursor is inside.
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 110, plot: barPlot, count: 4, style: .bar), 1)
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: 399, plot: barPlot, count: 4, style: .bar), 3)
        XCTAssertEqual(StatisticsChartMath.hoveredIndex(x: -20, plot: barPlot, count: 4, style: .bar), 0)
        XCTAssertEqual(StatisticsChartMath.dataX(index: 1, plot: barPlot, count: 4, style: .bar), 150)
        // Nothing drawn, nothing to hover.
        XCTAssertNil(StatisticsChartMath.hoveredIndex(x: 0, plot: barPlot, count: 0, style: .bar))
    }

    // MARK: 7 performance / non-blocking

    func testRecordPerformsNoFileIO() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        // Long coalescing window: nothing may write during this test.
        let service = makeService(writer: writer, calendar: calendar, now: now,
                                  coalescingDelay: 60, maxDelay: 60)
        await service.awaitReady()

        for _ in 0..<1000 {
            service.record(.previewPresented, source: .globalShortcut, at: now)
        }
        XCTAssertEqual(writer.writeCount, 0, "record() must not touch the writer")
    }

    func testBurstOfRecordsCoalescesIntoOneWrite() async throws {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now,
                                  coalescingDelay: 0.05, maxDelay: 0.2)
        await service.awaitReady()

        for _ in 0..<100 {
            service.record(.quickSwitch, source: .appShortcut, at: now)
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(writer.writeCount, 1, "one coalescing window should produce one write")
        XCTAssertEqual(writer.written.last?.days["2026-09-29"]?["quickSwitch:appShortcut"], 100)
    }

    func testContinuousRecordingStillFlushesWithinTheHardLimit() async throws {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        // Coalescing delay far longer than the hard limit: the limit must win.
        let service = makeService(writer: writer, calendar: calendar, now: now,
                                  coalescingDelay: 10, maxDelay: 0.05)
        await service.awaitReady()

        for _ in 0..<10 {
            service.record(.workspacePresented, source: .workspaceShortcut, at: now)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertGreaterThanOrEqual(writer.writeCount, 1, "the 5 s hard limit must not starve the write")
    }

    func testWritesAreSingleFlight() async throws {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        writer.writeDelay = 0.05
        let service = makeService(writer: writer, calendar: calendar, now: now,
                                  coalescingDelay: 0.01, maxDelay: 0.02)
        await service.awaitReady()

        for _ in 0..<50 {
            service.record(.quickSwitch, source: .appShortcut, at: now)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(writer.maxConcurrentWrites, 1, "only one write may be in flight")
        XCTAssertGreaterThanOrEqual(writer.writeCount, 1)
    }

    func testFlushSyncWritesBeforeTermination() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now,
                                  coalescingDelay: 60, maxDelay: 60)
        await service.awaitReady()
        service.record(.quickSwitch, source: .appShortcut, at: now)

        service.flushSync(timeout: 0.5)
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(writer.written.last?.days["2026-09-29"]?["quickSwitch:appShortcut"], 1)
    }

    func testWriteFailureKeepsDataInMemoryAndRetriesOnce() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        writer.writeError = TestError.intended
        let service = makeService(writer: writer, calendar: calendar, now: now)
        await service.awaitReady()
        service.record(.quickSwitch, source: .appShortcut, at: now)
        await service.flush()

        XCTAssertEqual(writer.writeCount, 2, "one attempt plus one retry")
        XCTAssertEqual(service.snapshot().totals().quickSwitchCount, 1, "data must survive a failed write")

        // A later, healthy flush succeeds and clears the dirty flag.
        writer.writeError = nil
        await service.flush()
        XCTAssertEqual(writer.written.last?.days["2026-09-29"]?["quickSwitch:appShortcut"], 1)
    }

    func testRecordThroughput() async {
        let calendar = makeCalendar()
        let now = date(2026, 9, 29, calendar: calendar)
        let writer = RecordingStatisticsWriter()
        let service = makeService(writer: writer, calendar: calendar, now: now,
                                  coalescingDelay: 60, maxDelay: 60)
        await service.awaitReady()

        let iterations = 100_000
        let started = Date()
        for index in 0..<iterations {
            let source: UsageEventSource = index % 2 == 0 ? .globalShortcut : .statusMenu
            service.record(.previewPresented, source: source, at: now)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(writer.writeCount, 0)
        // ~1 us/record in Release; this is a Debug build, so the bound is loose
        // on purpose -- it still catches an accidental synchronous write or a
        // DateFormatter per record (three orders of magnitude slower).
        XCTAssertLessThan(elapsed, 1.0, "100k records took \(elapsed)s")
    }
}

// MARK: - Atomic writer (real files)

final class UsageStatisticsWriterTests: XCTestCase {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-statistics-writer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRoundTripPreservesUnknownKeys() throws {
        let fileURL = tempDirectory().appendingPathComponent("usage-statistics.json")
        let writer = UsageStatisticsAtomicWriter(fileURL: fileURL)
        XCTAssertNil(try writer.load())

        let file = UsageStatisticsFile(days: [
            "2026-09-29": [
                "quickSwitch:appShortcut": 4,
                "futureKind:futureSource": 9
            ]
        ])
        try writer.write(file)

        let loaded = try writer.load()
        XCTAssertEqual(loaded?.days["2026-09-29"]?["quickSwitch:appShortcut"], 4)
        XCTAssertEqual(loaded?.days["2026-09-29"]?["futureKind:futureSource"], 9)
        XCTAssertEqual(loaded?.schemaVersion, UsageStatisticsFile.currentSchemaVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("tmp").path))
    }

    func testCorruptFileIsBackedUpNotDeleted() throws {
        let fileURL = tempDirectory().appendingPathComponent("usage-statistics.json")
        try Data("{ this is not json".utf8).write(to: fileURL)
        let writer = UsageStatisticsAtomicWriter(fileURL: fileURL)

        XCTAssertNil(try writer.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testNewerSchemaVersionIsTreatedAsUnreadable() throws {
        let fileURL = tempDirectory().appendingPathComponent("usage-statistics.json")
        let encoder = JSONEncoder()
        try encoder.encode(UsageStatisticsFile(schemaVersion: 99,
                                               days: ["2026-09-29": ["quickSwitch:appShortcut": 1]]))
            .write(to: fileURL)
        let writer = UsageStatisticsAtomicWriter(fileURL: fileURL)

        XCTAssertNil(try writer.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))
    }
}
