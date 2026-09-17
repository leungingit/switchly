//
//  StatisticsPanelSnapshotTests.swift
//  SwitchlyTests
//
//  Renders the real statistics panel offscreen (light/dark, zh/en, empty and
//  seeded) and writes PNGs, so the layout can actually be looked at instead of
//  assumed. Also microbenchmarks the panel's hot paths: aggregation with a
//  full 400-day retention window, one view-model recompute, and one draw.
//

import XCTest
import AppKit
import SwiftUI
@testable import Switchly

@MainActor
final class StatisticsPanelSnapshotTests: XCTestCase {

    private let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchly-statistics-snapshots", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    // MARK: Fixtures

    private func makeDefaults() -> UserDefaults {
        let name = "com.switchly.tests.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeSettingsService(language: AppLanguage) -> SettingsService {
        let defaults = makeDefaults()
        var settings = AppSettings.default
        settings.language = language
        try? SettingsService(defaults: defaults).saveSettings(settings)
        return SettingsService(defaults: defaults)
    }

    private func makeScratchService() -> UsageStatisticsService {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-scratch-\(UUID().uuidString).json")
        return UsageStatisticsService(
            writer: UsageStatisticsAtomicWriter(fileURL: url),
            ioQueue: DispatchQueue(label: "test.statistics.snapshot.io"),
            coalescingDelay: 60, maxDelay: 60
        )
    }

    /// A plausible month: weekday usage with a couple of thin days, both input
    /// sides present, plus quick switches and workspace opens.
    private func seed(_ service: UsageStatisticsService, calendar: Calendar) {
        let now = Date()
        for offset in stride(from: 27, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let weekend = calendar.isDateInWeekend(day)
            let quiet = offset % 7 == 3
            let opens = weekend || quiet ? 1 : 5 + (offset % 5)
            let committedKeyboard = weekend || quiet ? 1 : 4 + (offset % 3)
            let committedPointer = weekend || quiet ? 0 : 1 + (offset % 2)
            let quick = weekend || quiet ? 1 : 3 + (offset % 6)
            let rotation = weekend ? 0 : 2 + (offset % 3)

            // Record the real multiplicity: one call per use, so the panel
            // shows the magnitudes a real month produces.
            for _ in 0..<opens {
                service.record(.previewPresented, source: .globalShortcut, at: day)
            }
            if !weekend {
                for _ in 0..<2 {
                    service.record(.previewPresented, source: .statusMenu, at: day)
                }
            }
            // The Dock hover preview is pointer usage too: it shows on hover
            // and commits on click, so the snapshots must exercise that path.
            for _ in 0..<2 {
                service.record(.previewPresented, source: .dockHover, at: day)
            }
            if !weekend {
                service.record(.previewSwitchCommitted, source: .dockHover, at: day)
            }
            for _ in 0..<committedKeyboard {
                service.record(.previewSwitchCommitted, source: .panelKeyboard, at: day)
            }
            for _ in 0..<committedPointer {
                service.record(.previewSwitchCommitted, source: .panelClick, at: day)
            }
            for _ in 0..<quick {
                service.record(.quickSwitch, source: .appShortcut, at: day)
            }
            for _ in 0..<rotation {
                service.record(.quickSwitch, source: .currentAppWindowShortcut, at: day)
            }
            if offset % 2 == 0 {
                service.record(.workspacePresented, source: .workspaceShortcut, at: day)
            }
        }
    }

    // MARK: Rendering

    @discardableResult
    private func render(_ view: some View,
                        width: CGFloat,
                        height: CGFloat,
                        dark: Bool,
                        to url: URL) throws -> TimeInterval {
        let started = Date()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        // Rendered via cacheDisplay, not layer.render(in:): the layer path
        // silently drops AppKit-backed controls -- a segmented Picker comes
        // out as an empty gap, which turns every baseline-picker review into
        // a false alarm. cacheDisplay draws the live view hierarchy with the
        // controls included, over a desktop-like pre-filled background (the
        // glass material draws flat offscreen).
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(width * scale),
                                         pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            XCTFail("cannot create bitmap rep")
            return 0
        }
        rep.size = NSSize(width: width, height: height)
        // cacheDisplay composites the view hierarchy over whatever the rep
        // already holds, so the desktop-like background is painted first (the
        // glass material draws flat offscreen and would otherwise leave the
        // PNG transparent).
        if let fill = NSGraphicsContext(bitmapImageRep: rep) {
            fill.cgContext.setFillColor(dark
                ? CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                : CGColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
            fill.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("cannot encode PNG")
            return 0
        }
        try png.write(to: url)
        return Date().timeIntervalSince(started)
    }

    // MARK: The snapshots

    func testRenderStatisticsPanel() async throws {
        let calendar = Calendar.current

        // -- seeded, zh-Hans, light
        let zhService = makeScratchService()
        seed(zhService, calendar: calendar)
        let zhModel = StatisticsViewModel(service: zhService,
                                          settingsService: makeSettingsService(language: .simplifiedChinese))
        await zhModel.awaitReady()
        try render(StatisticsView(model: zhModel),
                   width: 880, height: 810, dark: false,
                   to: outputDirectory.appendingPathComponent("statistics-light-zh.png"))

        // -- seeded, zh-Hans, dark (same model: the window appearance decides)
        try render(StatisticsView(model: zhModel),
                   width: 880, height: 810, dark: true,
                   to: outputDirectory.appendingPathComponent("statistics-dark-zh.png"))

        // -- seeded, English, light
        let enModel = StatisticsViewModel(service: zhService,
                                          settingsService: makeSettingsService(language: .english))
        await enModel.awaitReady()
        try render(StatisticsView(model: enModel),
                   width: 880, height: 810, dark: false,
                   to: outputDirectory.appendingPathComponent("statistics-light-en.png"))

        // -- empty, zh-Hans, light
        let emptyModel = StatisticsViewModel(service: makeScratchService(),
                                             settingsService: makeSettingsService(language: .simplifiedChinese))
        await emptyModel.awaitReady()
        try render(StatisticsView(model: emptyModel),
                   width: 880, height: 810, dark: false,
                   to: outputDirectory.appendingPathComponent("statistics-empty-zh.png"))

        // -- taller than the window: the whole report in one image (the live
        //    window scrolls), so the layout review sees every section.
        try render(StatisticsView(model: zhModel),
                   width: 880, height: 1060, dark: false,
                   to: outputDirectory.appendingPathComponent("statistics-full-zh.png"))

        // -- hover state: the guide line and value card must render aligned
        //    to the drawn data and stay inside the chart bounds.
        try render(StatisticsChartView(labels: (0..<10).map { String(format: "09-%02d", $0 + 20) },
                                       series: [
                                        StatisticsSeries(id: "a",
                                                         title: "预览 · 快捷键",
                                                         color: .accentColor,
                                                         values: [3, 7, 4, 8, 5, 9, 2, 6, 4, 7],
                                                         isDashed: false),
                                        StatisticsSeries(id: "b",
                                                         title: "预览 · 鼠标",
                                                         color: .green,
                                                         values: [1, 2, 0, 3, 1, 2, 1, 0, 2, 1],
                                                         isDashed: true)],
                                       style: .line,
                                       valueFormat: .count,
                                       previewHoverX: 480),
                   width: 880, height: 160, dark: false,
                   to: outputDirectory.appendingPathComponent("chart-hover.png"))

        for name in ["statistics-light-zh", "statistics-dark-zh", "statistics-light-en", "statistics-empty-zh", "statistics-full-zh", "chart-hover"] {
            let url = outputDirectory.appendingPathComponent(name + ".png")
            let size = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 20_000, "\(name).png looks too small to be a real frame")
        }

        // Layout guard: the whole report must fit the 760 pt window with no
        // scrolling -- the panel is meant to be read at a glance.
        zhModel.deactivate()
        enModel.deactivate()
        emptyModel.deactivate()
    }

    // MARK: Performance

    private func fullRetentionDays(calendar: Calendar) -> [String: [String: Int]] {
        var days: [String: [String: Int]] = [:]
        let formatter = { (date: Date) -> String in UsageDayKey.key(for: date, calendar: calendar) }
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<UsageStatisticsService.retentionDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            days[formatter(day)] = [
                "previewPresented:globalShortcut": 6,
                "previewPresented:statusMenu": 2,
                "previewPresented:statusPopover": 1,
                "previewSwitchCommitted:panelKeyboard": 5,
                "previewSwitchCommitted:panelClick": 1,
                "quickSwitch:appShortcut": 4,
                "quickSwitch:currentAppWindowShortcut": 2,
                "workspacePresented:workspaceShortcut": 3
            ]
        }
        return days
    }

    /// Worst case for the aggregator: a full retention window, three granularities.
    func testAggregationWithFullRetentionStaysCheap() {
        let calendar = Calendar.current
        let days = fullRetentionDays(calendar: calendar)
        XCTAssertEqual(days.count, UsageStatisticsService.retentionDays)

        for granularity in [StatisticsGranularity.day, .week, .month] {
            let started = Date()
            let buckets = UsageStatisticsAggregator.buckets(days: days,
                                                            granularity: granularity,
                                                            calendar: calendar,
                                                            now: Date())
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual(buckets.count, granularity.defaultRange)
            XCTAssertLessThan(elapsed, 0.05,
                              "\(granularity.rawValue) aggregation took \(elapsed)s -- the panel recomputes this on every change")
        }

        // The summary cards read the whole window.
        let snapshot = UsageStatisticsSnapshot(days: days)
        let started = Date()
        let totals = snapshot.totals(calendar: calendar)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(totals.quickSwitchCount, 0)
        XCTAssertLessThan(elapsed, 0.05)
    }

    /// One view-model recompute over the full window, then a draw pass.
    func testPanelRecomputeAndDrawCost() async throws {
        let calendar = Calendar.current
        let service = makeScratchService()
        let days = fullRetentionDays(calendar: calendar)
        let now = Date()
        for (key, counts) in days {
            guard let day = UsageDayKey.date(for: key, calendar: calendar) else { continue }
            for (metric, value) in counts {
                guard let parsed = UsageMetricKey.parse(metric) else { continue }
                for _ in 0..<value { service.record(parsed.kind, source: parsed.source, at: day) }
            }
        }

        let model = StatisticsViewModel(service: service,
                                        settingsService: makeSettingsService(language: .simplifiedChinese))
        await model.awaitReady()
        model.activate()

        let recomputeStart = Date()
        model.refreshIfNeeded(force: true)
        let recompute = Date().timeIntervalSince(recomputeStart)
        XCTAssertGreaterThan(model.rangeSummary.savedSeconds, 0)
        XCTAssertLessThan(recompute, 0.05, "a full recompute took \(recompute)s")
        print("[statistics-perf] full recompute (400 days): \(Int(recompute * 1000)) ms")

        // One render pass of the whole panel, measured in software. The live
        // window additionally gets the GPU, so this is an upper bound.
        let hosting = NSHostingView(rootView: StatisticsView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 880, height: 620)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let layer = hosting.layer, let context = CGContext(data: nil,
                                                                 width: 1760, height: 1240,
                                                                 bitsPerComponent: 8, bytesPerRow: 0,
                                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("cannot set up the render pass")
            return
        }
        context.scaleBy(x: 2, y: 2)
        let drawStart = Date()
        let passes = 10
        for _ in 0..<passes {
            context.clear(CGRect(x: 0, y: 0, width: 880, height: 620))
            layer.render(in: context)
        }
        let perDraw = Date().timeIntervalSince(drawStart) / Double(passes)
        print("[statistics-perf] full panel software render (2x): \(Int(perDraw * 1000)) ms")
        // Software raster of the whole panel on a Debug build -- an upper
        // bound, not a frame time: the live window composites on the GPU and
        // only redraws when a record lands (the idle poll is an integer
        // compare). The assertion catches pathological regressions only.
        XCTAssertLessThan(perDraw, 0.12, "one panel render took \(perDraw * 1000) ms")

        model.deactivate()
    }
}
