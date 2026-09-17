//
//  UsageStatisticsService.swift
//  Switchly
//
//  Local usage counters. See docs/plan/2026-09-29-statistics-panel.md (v3).
//
//  Two paths, deliberately disjoint:
//
//    record()  -- main thread, O(1), NO I/O. A dictionary increment plus a
//                 cached day key. Nothing here may touch the file system.
//    flush()   -- ioQueue (qos .utility), coalesced to at most one write in
//                 flight, always an atomic whole-file replace.
//
//  The split is the whole point: the shortcut callback that records a count
//  must never wait on a disk.
//

import Foundation

// MARK: - Persistence boundary

/// The file system, behind a protocol so tests can count writes (and so the
/// service itself never mentions `FileManager`).
protocol UsageStatisticsWriting: Sendable {
    /// Returns nil when no file exists yet.
    func load() throws -> UsageStatisticsFile?
    func write(_ file: UsageStatisticsFile) throws
}

final class UsageStatisticsAtomicWriter: UsageStatisticsWriting, @unchecked Sendable {
    static let directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Switchly", isDirectory: true)
    }()

    static var defaultFileURL: URL {
        directoryURL.appendingPathComponent("usage-statistics.json")
    }

    let fileURL: URL

    private var temporaryURL: URL { fileURL.appendingPathExtension("tmp") }
    private var corruptURL: URL { fileURL.appendingPathExtension("corrupt") }

    init(fileURL: URL = UsageStatisticsAtomicWriter.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> UsageStatisticsFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            let file = try JSONDecoder().decode(UsageStatisticsFile.self, from: data)
            guard file.isReadable else {
                AppLogger.error("Usage statistics schemaVersion is newer than this build; keeping the file and starting empty")
                try? backUpCorruptFile()
                return nil
            }
            return file
        } catch {
            // Never silently delete user data: park it next to the live file.
            AppLogger.error("Usage statistics file is unreadable; backing it up. error=\(error)")
            try? backUpCorruptFile()
            return nil
        }
    }

    func write(_ file: UsageStatisticsFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    private func backUpCorruptFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if FileManager.default.fileExists(atPath: corruptURL.path) {
            try FileManager.default.removeItem(at: corruptURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }
}

// MARK: - Service

@MainActor
protocol UsageStatisticsServiceProtocol: AnyObject {
    /// Main thread, O(1), no I/O.
    func record(_ kind: UsageEventKind, source: UsageEventSource, at date: Date)
    /// Value copy of the in-memory state.
    func snapshot() -> UsageStatisticsSnapshot
    func clear()
    /// Coalesced write on the io queue.
    func flush() async
    /// Termination only: waits at most `timeout`.
    func flushSync(timeout: TimeInterval)
}

@MainActor
final class UsageStatisticsService: UsageStatisticsServiceProtocol {
    static let shared = UsageStatisticsService()

    static let retentionDays = 400
    static let defaultFileURL = UsageStatisticsAtomicWriter.defaultFileURL

    /// The Preferences switch. Read on every record, so it is a plain flag
    /// rather than a settings load.
    var isEnabled = true

    /// Bumped on every mutation so the panel can tell when its cached
    /// aggregation is stale without diffing dictionaries.
    private(set) var revision = 0

    private let writer: UsageStatisticsWriting
    private let calendar: Calendar
    private let now: () -> Date
    private let ioQueue: DispatchQueue
    private let coalescingDelay: TimeInterval
    private let maxDelay: TimeInterval

    private var days: [String: [String: Int]] = [:]
    private var isDirty = false
    private var writeGeneration = 0
    private var firstDirtyAt: Date?
    private var pendingWrite: DispatchWorkItem?
    private var isWriting = false
    private var suddenTerminationDisabled = false
    private var didLoad = false

    private var cachedDayStart: Date?
    private var cachedDayKey: String?

    init(writer: UsageStatisticsWriting = UsageStatisticsAtomicWriter(),
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init,
         ioQueue: DispatchQueue = DispatchQueue(label: "com.switchly.usage-statistics.io", qos: .utility),
         coalescingDelay: TimeInterval = 2,
         maxDelay: TimeInterval = 5) {
        self.writer = writer
        self.calendar = calendar
        self.now = now
        self.ioQueue = ioQueue
        self.coalescingDelay = coalescingDelay
        self.maxDelay = maxDelay
    }

    // MARK: Loading

    /// Loads the file off the main thread. Safe to call repeatedly and safe to
    /// call after records have already happened (they win the merge).
    func awaitReady() async {
        guard !didLoad else { return }
        let writer = self.writer
        let queue = self.ioQueue
        let loaded: UsageStatisticsFile? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (try? writer.load()) ?? nil)
            }
        }
        didLoad = true
        guard let loaded else { return }

        var merged = loaded.days
        for (key, counts) in days {
            merged[key, default: [:]].merge(counts) { $0 + $1 }
        }
        days = UsageStatisticsAggregator.prune(days: merged,
                                               keepingDays: Self.retentionDays,
                                               calendar: calendar,
                                               now: now())
        isDirty = false
    }

    // MARK: Recording (main thread, zero I/O)

    func record(_ kind: UsageEventKind, source: UsageEventSource, at date: Date) {
        guard isEnabled else { return }
        let key = dayKey(for: date)
        days[key, default: [:]][UsageMetricKey.key(kind, source), default: 0] += 1
        revision &+= 1
        writeGeneration &+= 1
        markDirty()
    }

    /// Cached because the record path runs inside shortcut callbacks.
    private func dayKey(for date: Date) -> String {
        let dayStart = calendar.startOfDay(for: date)
        if let cachedDayStart, cachedDayStart == dayStart, let cachedDayKey {
            return cachedDayKey
        }
        let key = UsageDayKey.key(for: date, calendar: calendar)
        cachedDayStart = dayStart
        cachedDayKey = key
        return key
    }

    func snapshot() -> UsageStatisticsSnapshot {
        UsageStatisticsSnapshot(days: days)
    }

    func clear() {
        days = [:]
        revision &+= 1
        writeGeneration &+= 1
        isDirty = true
        firstDirtyAt = now()
        disableSuddenTerminationIfNeeded()
        scheduleCoalescedWrite()
    }

    // MARK: Dirty tracking

    private func markDirty() {
        if !isDirty {
            isDirty = true
            firstDirtyAt = now()
            disableSuddenTerminationIfNeeded()
        }
        scheduleCoalescedWrite()
    }

    private func disableSuddenTerminationIfNeeded() {
        guard !suddenTerminationDisabled else { return }
        suddenTerminationDisabled = true
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    private func enableSuddenTerminationIfNeeded() {
        guard suddenTerminationDisabled else { return }
        suddenTerminationDisabled = false
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    /// Coalescing window: 2 s after the first dirty record, and never later
    /// than `maxDelay` -- a burst of shortcut presses cannot postpone
    /// the write forever.
    private func scheduleCoalescedWrite() {
        guard pendingWrite == nil else { return }
        let elapsed = firstDirtyAt.map { now().timeIntervalSince($0) } ?? 0
        let remaining = max(0, maxDelay - elapsed)
        let delay = min(coalescingDelay, remaining)
        let queue = ioQueue

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pendingWrite = nil
                await self?.writeNow()
            }
        }
        pendingWrite = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Writing (io queue)

    private func writeNow() async {
        guard isDirty else { return }
        guard !isWriting else {
            scheduleCoalescedWrite()
            return
        }
        isWriting = true

        let generation = writeGeneration
        let file = UsageStatisticsFile(days: days)
        let written = await Self.performWrite(file, writer: writer, queue: ioQueue)
        isWriting = false

        if written, generation == writeGeneration {
            isDirty = false
            firstDirtyAt = nil
            enableSuddenTerminationIfNeeded()
        } else if isDirty {
            scheduleCoalescedWrite()
        }
    }

    func flush() async {
        guard isDirty else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        await writeNow()
    }

    func flushSync(timeout: TimeInterval) {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard isDirty else { return }

        let generation = writeGeneration
        let file = UsageStatisticsFile(days: days)
        let writer = self.writer
        let queue = ioQueue
        let group = DispatchGroup()
        group.enter()
        queue.async {
            defer { group.leave() }
            do {
                try writer.write(file)
            } catch {
                AppLogger.error("Failed to write usage statistics on termination. error=\(error)")
            }
        }
        if group.wait(timeout: .now() + timeout) == .success, generation == writeGeneration {
            isDirty = false
            firstDirtyAt = nil
            enableSuddenTerminationIfNeeded()
        }
    }

    /// One retry, then keep the data in memory and try again in the next
    /// window. Never throws into the caller: a statistics write must not be
    /// able to break a switch.
    private nonisolated static func performWrite(_ file: UsageStatisticsFile,
                                                 writer: UsageStatisticsWriting,
                                                 queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try writer.write(file)
                    continuation.resume(returning: true)
                } catch {
                    do {
                        try writer.write(file)
                        continuation.resume(returning: true)
                    } catch {
                        AppLogger.error("Failed to write usage statistics after retry. error=\(error)")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }
}
