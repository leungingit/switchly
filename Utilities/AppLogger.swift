//
//  AppLogger.swift
//  Switchly
//
//  File-backed debug logging.
//
//  The log is written to `~/Library/Logs/Switchly/Switchly.log` and rotated at
//  a bounded size so a long-running menu bar app cannot fill the disk: the
//  previous unbounded file had reached 6.9 GB, which also made it impractical
//  to read back when diagnosing a switch failure.
//
//  Three write paths exist:
//  - `info` / `warning` / `error`: durable, rotated to file. These carry the
//    switch pipeline's decision trail and are what a diagnosis reads.
//  - `debug`: durable, rotated to file. For low-frequency diagnostics.
//  - `verbose`: stdout only, never written to disk. For per-tick / per-capture
//    chatter that would otherwise dominate the file.
//

import Foundation

enum AppLogger {
    private static let lock = NSLock()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static let logDirectory: URL = {
        let baseURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("Logs/Switchly", isDirectory: true)
    }()

    static let logFileURL: URL = logDirectory.appendingPathComponent("Switchly.log")

    /// Rotation bounds: the live file plus `maxRotatedFileCount` archives.
    static let maxLogFileSize: UInt64 = 5 * 1024 * 1024
    static let maxRotatedFileCount = 3

    private static var writesSinceSizeCheck = 0
    private static let sizeCheckInterval = 200

    private static var throttleState: [String: Date] = [:]

    static var logFilePaths: [String] {
        [logFileURL.path]
            + (1...maxRotatedFileCount).map { rotatedFileURL(index: $0).path }
    }

    static func configure() {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            info("Logger configured. logFiles=\(logFilePaths.joined(separator: ", ")), maxFileSize=\(maxLogFileSize)")
        } catch {
            print("[Switchly] Failed to configure logger: \(error)")
        }
    }

    static func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        write(level: "DEBUG", message: message, file: file, line: line)
    }

    /// High-frequency diagnostics that must never reach the log file. Kept out
    /// of `debug` so the rotated log keeps weeks of switch history instead of
    /// hours of thumbnail chatter.
    static func verbose(_ message: String, file: String = #fileID, line: Int = #line) {
        print("[Switchly] \(dateFormatter.string(from: Date())) [VERBOSE] \(file):\(line) \(message)")
    }

    static func info(_ message: String, file: String = #fileID, line: Int = #line) {
        write(level: "INFO", message: message, file: file, line: line)
    }

    static func warning(_ message: String, file: String = #fileID, line: Int = #line) {
        write(level: "WARN", message: message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #fileID, line: Int = #line) {
        write(level: "ERROR", message: message, file: file, line: line)
    }

    /// Writes a warning at most once per `interval` for a given key.
    ///
    /// Thumbnail capture failures repeat on every monitor tick for as long as a
    /// window stays un-capturable (measured: 12k+ identical lines), which is
    /// enough on its own to make the log unreadable.
    static func throttledWarning(
        key: String,
        _ message: String,
        interval: TimeInterval = 10,
        file: String = #fileID,
        line: Int = #line
    ) {
        guard shouldEmit(key: key, interval: interval) else { return }
        warning(message, file: file, line: line)
    }

    /// Throttled counterpart of `error`, for failures that repeat every tick.
    static func throttledError(
        key: String,
        _ message: String,
        interval: TimeInterval = 10,
        file: String = #fileID,
        line: Int = #line
    ) {
        guard shouldEmit(key: key, interval: interval) else { return }
        error(message, file: file, line: line)
    }

    private static func shouldEmit(key: String, interval: TimeInterval) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if let last = throttleState[key], now.timeIntervalSince(last) < interval {
            return false
        }
        throttleState[key] = now
        if throttleState.count > 512 {
            throttleState.removeAll()
        }
        return true
    }

    private static func write(level: String, message: String, file: String, line: Int) {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "\(timestamp) [\(level)] \(file):\(line) \(message)\n"
        print("[Switchly] \(entry)", terminator: "")

        lock.lock()
        defer { lock.unlock() }

        guard let data = entry.data(using: .utf8) else {
            return
        }

        do {
            try write(data, to: logFileURL, in: logDirectory)
        } catch {
            print("[Switchly] Failed to write log entry: \(error)")
        }
    }

    private static func write(_ data: Data, to fileURL: URL, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        rotateIfNeeded()

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func rotatedFileURL(index: Int) -> URL {
        logDirectory.appendingPathComponent("Switchly.log.\(index)")
    }

    /// Shifts `Switchly.log` → `.1` → `.2` → `.3` once the live file exceeds
    /// `maxLogFileSize`. The size check is amortized over several writes.
    private static func rotateIfNeeded() {
        writesSinceSizeCheck += 1
        guard writesSinceSizeCheck >= sizeCheckInterval else { return }
        writesSinceSizeCheck = 0

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size >= maxLogFileSize else {
            return
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: rotatedFileURL(index: maxRotatedFileCount))
        if maxRotatedFileCount > 1 {
            for index in stride(from: maxRotatedFileCount - 1, through: 1, by: -1) {
                try? fileManager.moveItem(
                    at: rotatedFileURL(index: index),
                    to: rotatedFileURL(index: index + 1)
                )
            }
        }
        try? fileManager.moveItem(at: logFileURL, to: rotatedFileURL(index: 1))
        print("[Switchly] Rotated log file. archived=\(rotatedFileURL(index: 1).path)")
    }
}
