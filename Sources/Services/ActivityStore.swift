//
//  ActivityStore.swift
//  Switchly
//
//  Durable application-activity intervals backed by one private JSON file.
//

import Foundation

enum ActivityStoreError: Error, Equatable {
    case staleGeneration
    case invalidRetentionDays
    case invalidDateRange
    case queryRangeTooLong
    case invalidSession
    case unsupportedSchemaVersion(Int)
    case encodedDataTooLarge
    case unsafeStorage
}

actor ActivityStore {
    static let schemaVersion = 1
    static let defaultRetentionDays = 400
    static let supportedRetentionDays = [1, 7, 30, 90, 400]
    static let maximumSessions = 100_000
    static let maximumEncodedBytes = 64 * 1024 * 1024
    static let maximumQueryDays = 400
    static let fileName = "activity.json"
    static let temporaryPrefix = "activity.json.tmp-"
    static let corruptPrefix = "activity.corrupt-"

    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Switchly", isDirectory: true)
        .appendingPathComponent("Activity", isDirectory: true)

    private struct PersistedActivity: Codable {
        var schemaVersion: Int
        var retentionDays: Int
        var sessions: [ActivitySession]

        init(
            schemaVersion: Int = ActivityStore.schemaVersion,
            retentionDays: Int = ActivityStore.defaultRetentionDays,
            sessions: [ActivitySession] = []
        ) {
            self.schemaVersion = schemaVersion
            self.retentionDays = retentionDays
            self.sessions = sessions
        }
    }

    private struct FileSignature: Equatable {
        let size: Int64
        let modificationDate: Date?
        let fileIdentifier: Data?
    }

    private struct CachedActivity {
        let signature: FileSignature
        let persisted: PersistedActivity
    }

    private struct CorruptBackup {
        let url: URL
        let size: Int64
        let modificationDate: Date?
    }

    private let directory: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private var activeGeneration: UUID?
    private var cachedActivity: CachedActivity?

    private var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    init(
        directory: URL = ActivityStore.defaultDirectory,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.directory = directory.standardizedFileURL
        self.now = now
        self.fileManager = fileManager
    }

    /// Establishes the write generation once for this service lifetime. A
    /// later `clear` invalidates it and permits a new service generation.
    func begin(generation: UUID) throws {
        guard activeGeneration == nil else { return }
        activeGeneration = generation
    }

    func apply(
        _ sessions: [ActivitySession],
        truncateAfter: Date? = nil,
        retentionDays: Int = ActivityStore.defaultRetentionDays,
        generation: UUID
    ) throws {
        guard activeGeneration == generation else {
            throw ActivityStoreError.staleGeneration
        }
        try validateRetention(retentionDays)
        for session in sessions {
            try validate(session)
        }

        try ensureDirectory()
        try removeTemporaryFiles()
        let persisted = try load()

        var records: [UUID: ActivitySession] = [:]
        for session in persisted.sessions {
            try validate(session)
            if let normalized = truncate(session, after: truncateAfter) {
                records[normalized.id] = normalized
            }
        }
        for session in sessions {
            if let normalized = truncate(session, after: truncateAfter) {
                records[normalized.id] = normalized
            }
        }

        let retained = retain(
            Array(records.values),
            retentionDays: retentionDays,
            relativeTo: now()
        )
        let bounded = try enforceLimits(retained, retentionDays: retentionDays)
        let data = try encode(PersistedActivity(
            retentionDays: retentionDays,
            sessions: bounded
        ))
        try write(data, retentionDays: retentionDays)
    }

    func read(from: Date, to: Date) throws -> [ActivitySession] {
        try validateRange(from: from, to: to)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        try removeTemporaryFiles()
        var persisted = try load()
        try pruneCorruptBackups(
            retentionDays: persisted.retentionDays,
            reservedLiveBytes: try liveFileSize()
        )
        if persisted.sessions.isEmpty,
           !fileManager.fileExists(atPath: fileURL.path) {
            return []
        }

        try validateRetention(persisted.retentionDays)
        persisted.sessions = retain(
            persisted.sessions,
            retentionDays: persisted.retentionDays,
            relativeTo: now()
        )

        return persisted.sessions
            .filter { $0.start < to && $0.end > from }
            .sorted(by: Self.sessionOrder)
    }

    /// Invalidates the generation before touching disk, so an old caller can
    /// never refill records while clear is still removing them.
    func clear(generation: UUID) throws {
        guard activeGeneration == generation else {
            throw ActivityStoreError.staleGeneration
        }
        activeGeneration = nil
        cachedActivity = nil

        guard fileManager.fileExists(atPath: directory.path) else { return }
        let urls = try contents()
        for url in urls
        where url.lastPathComponent == Self.fileName
            || url.lastPathComponent.hasPrefix(Self.temporaryPrefix)
            || url.lastPathComponent.hasPrefix(Self.corruptPrefix) {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func prune(retentionDays: Int) throws {
        try validateRetention(retentionDays)
        guard fileManager.fileExists(atPath: directory.path) else {
            try removeTemporaryFiles()
            return
        }

        try removeTemporaryFiles()
        var persisted = try load()
        persisted.retentionDays = retentionDays
        persisted.sessions = retain(
            persisted.sessions,
            retentionDays: retentionDays,
            relativeTo: now()
        )

        if fileManager.fileExists(atPath: fileURL.path) || !persisted.sessions.isEmpty {
            persisted.sessions = try enforceLimits(
                persisted.sessions,
                retentionDays: retentionDays
            )
            let data = try encode(persisted)
            try write(data, retentionDays: retentionDays)
        } else {
            try pruneCorruptBackups(retentionDays: retentionDays, reservedLiveBytes: 0)
        }
    }

    func availableFrom(retentionDays: Int) throws -> Date? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let persisted = try load()
        let rows = retain(persisted.sessions, retentionDays: retentionDays, relativeTo: now())
        return rows.isEmpty ? nil : now().addingTimeInterval(-Double(retentionDays) * 86400)
    }

    private static func sessionOrder(_ lhs: ActivitySession, _ rhs: ActivitySession) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func validate(_ session: ActivitySession) throws {
        guard session.start < session.end,
              session.seconds.isFinite,
              session.seconds >= 0 else {
            throw ActivityStoreError.invalidSession
        }
    }

    private func validateRetention(_ days: Int) throws {
        guard Self.supportedRetentionDays.contains(days) else {
            throw ActivityStoreError.invalidRetentionDays
        }
    }

    private func validateRange(from: Date, to: Date) throws {
        let interval = to.timeIntervalSince(from)
        guard interval.isFinite,
              interval > 0,
              interval <= Double(Self.maximumQueryDays) * 86_400 else {
            if Self.isOrderedRange(from: from, to: to) {
                throw ActivityStoreError.queryRangeTooLong
            }
            throw ActivityStoreError.invalidDateRange
        }
    }

    private static func isOrderedRange(from: Date, to: Date) -> Bool {
        let interval = to.timeIntervalSince(from)
        return interval.isFinite && interval > 0
    }

    private func truncate(_ session: ActivitySession, after cutoff: Date?) -> ActivitySession? {
        guard let cutoff, session.end > cutoff else { return session }
        guard session.start < cutoff else { return nil }

        let span = session.end.timeIntervalSince(session.start)
        guard span > 0 else { return nil }
        let retainedFraction = cutoff.timeIntervalSince(session.start) / span
        return ActivitySession(
            id: session.id,
            bundleID: session.bundleID,
            appName: session.appName,
            start: session.start,
            end: cutoff,
            seconds: session.seconds * retainedFraction,
            endReason: session.endReason
        )
    }

    private func retain(
        _ sessions: [ActivitySession],
        retentionDays: Int,
        relativeTo date: Date
    ) -> [ActivitySession] {
        let cutoff = date.addingTimeInterval(-Double(retentionDays) * 86_400)
        return sessions
            .filter { $0.end > cutoff }
            .map { session in
                guard session.start < cutoff else { return session }
                let duration = session.end.timeIntervalSince(session.start)
                return ActivitySession(id: session.id, bundleID: session.bundleID, appName: session.appName,
                                       start: cutoff, end: session.end,
                                       seconds: session.seconds * session.end.timeIntervalSince(cutoff) / max(0.001, duration), endReason: session.endReason)
            }
            .sorted(by: Self.sessionOrder)
    }

    private func enforceLimits(
        _ sessions: [ActivitySession],
        retentionDays: Int
    ) throws -> [ActivitySession] {
        let ordered = sessions.sorted(by: Self.sessionOrder)
        let capped = Array(ordered.suffix(Self.maximumSessions))
        guard try encodedSize(of: capped, retentionDays: retentionDays) > Self.maximumEncodedBytes else {
            return capped
        }

        // Encoded size grows with the retained suffix; find the largest suffix
        // under the byte limit while continuing to evict the oldest records.
        var low = 0
        var high = capped.count
        while low < high {
            let middle = (low + high) / 2
            let candidate = Array(capped.suffix(from: middle))
            if try encodedSize(of: candidate, retentionDays: retentionDays) <= Self.maximumEncodedBytes {
                high = middle
            } else {
                low = middle + 1
            }
        }

        let result = Array(capped.suffix(from: low))
        guard try encodedSize(of: result, retentionDays: retentionDays) <= Self.maximumEncodedBytes else {
            throw ActivityStoreError.encodedDataTooLarge
        }
        return result
    }

    private func encodedSize(
        of sessions: [ActivitySession],
        retentionDays: Int
    ) throws -> Int {
        try encode(PersistedActivity(retentionDays: retentionDays, sessions: sessions)).count
    }

    private func encode(_ persisted: PersistedActivity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(persisted)
    }

    private func decode(_ data: Data) throws -> PersistedActivity {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(PersistedActivity.self, from: data)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try requireSafeDirectory(expectsExistingDirectory: true)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try requireSafeDirectory(expectsExistingDirectory: true)
    }

    private func write(_ data: Data, retentionDays: Int) throws {
        guard data.count <= Self.maximumEncodedBytes else {
            throw ActivityStoreError.encodedDataTooLarge
        }
        try ensureDirectory()
        try pruneCorruptBackups(
            retentionDays: retentionDays,
            reservedLiveBytes: Int64(data.count)
        )
        cachedActivity = nil

        let temporaryURL = directory.appendingPathComponent(
            "\(Self.temporaryPrefix)\(UUID().uuidString)",
            isDirectory: false
        )
        var installed = false
        defer {
            if !installed, fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ActivityStoreError.unsafeStorage
            }
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        installed = true

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func load(attempt: Int = 0) throws -> PersistedActivity {
        if fileManager.fileExists(atPath: directory.path) {
            try requireSafeDirectory(expectsExistingDirectory: true)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedActivity = nil
            return PersistedActivity()
        }

        let values = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            cachedActivity = nil
            throw ActivityStoreError.unsafeStorage
        }
        guard let fileSize = values.fileSize else {
            cachedActivity = nil
            throw ActivityStoreError.unsafeStorage
        }
        guard fileSize <= Self.maximumEncodedBytes else {
            cachedActivity = nil
            throw ActivityStoreError.encodedDataTooLarge
        }

        let signature = FileSignature(
            size: Int64(fileSize),
            modificationDate: values.contentModificationDate,
            fileIdentifier: Self.encodedResourceIdentifier(values.fileResourceIdentifier)
        )
        if let cachedActivity, cachedActivity.signature == signature {
            return cachedActivity.persisted
        }

        let data = try Data(contentsOf: fileURL)
        let currentValues = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        let currentSignature = FileSignature(
            size: Int64(currentValues.fileSize ?? data.count),
            modificationDate: currentValues.contentModificationDate,
            fileIdentifier: Self.encodedResourceIdentifier(currentValues.fileResourceIdentifier)
        )
        guard currentValues.isRegularFile == true,
              currentValues.isSymbolicLink != true,
              currentSignature == signature else {
            cachedActivity = nil
            guard attempt == 0 else {
                throw ActivityStoreError.unsafeStorage
            }
            return try load(attempt: 1)
        }

        let parsedObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = (parsedObject?["schemaVersion"] as? NSNumber)?.intValue
        if let schema, schema > Self.schemaVersion {
            cachedActivity = nil
            throw ActivityStoreError.unsupportedSchemaVersion(schema)
        }

        guard schema == Self.schemaVersion else {
            try quarantineLiveFile(
                retentionDays: parsedRetentionDays(parsedObject) ?? Self.defaultRetentionDays
            )
            return PersistedActivity()
        }

        do {
            let persisted = try decode(data)
            guard persisted.schemaVersion == Self.schemaVersion else {
                if persisted.schemaVersion > Self.schemaVersion {
                    throw ActivityStoreError.unsupportedSchemaVersion(persisted.schemaVersion)
                }
                throw ActivityStoreError.unsafeStorage
            }
            try validateRetention(persisted.retentionDays)
            for session in persisted.sessions {
                try validate(session)
            }
            cachedActivity = CachedActivity(signature: signature, persisted: persisted)
            return persisted
        } catch let ActivityStoreError.unsupportedSchemaVersion(version) {
            throw ActivityStoreError.unsupportedSchemaVersion(version)
        } catch {
            try quarantineLiveFile(
                retentionDays: parsedRetentionDays(parsedObject) ?? Self.defaultRetentionDays
            )
            return PersistedActivity()
        }
    }

    private func parsedRetentionDays(_ object: [String: Any]?) -> Int? {
        guard let value = (object?["retentionDays"] as? NSNumber)?.intValue,
              Self.supportedRetentionDays.contains(value) else {
            return nil
        }
        return value
    }

    private static func encodedResourceIdentifier(
        _ value: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> Data? {
        guard let value else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        )
    }

    private func quarantineLiveFile(retentionDays: Int) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        cachedActivity = nil
        let backupURL = directory.appendingPathComponent(
            "\(Self.corruptPrefix)\(Int(now().timeIntervalSince1970))-\(UUID().uuidString).json",
            isDirectory: false
        )
        try fileManager.moveItem(at: fileURL, to: backupURL)
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: now()
            ],
            ofItemAtPath: backupURL.path
        )
        try pruneCorruptBackups(retentionDays: retentionDays, reservedLiveBytes: 0)
    }

    private func liveFileSize() throws -> Int64 {
        guard fileManager.fileExists(atPath: fileURL.path) else { return 0 }
        let values = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            throw ActivityStoreError.unsafeStorage
        }
        return Int64(fileSize)
    }

    private func pruneCorruptBackups(
        retentionDays: Int,
        reservedLiveBytes: Int64
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        var backups: [CorruptBackup] = []
        var totalBackupBytes: Int64 = 0

        for url in try contents() where url.lastPathComponent.hasPrefix(Self.corruptPrefix) {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true
                || values.isRegularFile != true
                || (values.contentModificationDate ?? .distantPast) <= cutoff {
                try fileManager.removeItem(at: url)
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            totalBackupBytes += size
            backups.append(CorruptBackup(
                url: url,
                size: size,
                modificationDate: values.contentModificationDate
            ))
        }

        let availableBackupBytes = max(
            0,
            Int64(Self.maximumEncodedBytes) - reservedLiveBytes
        )
        let oldestFirst = backups.sorted { lhs, rhs in
            let lhsDate = lhs.modificationDate ?? .distantPast
            let rhsDate = rhs.modificationDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        for backup in oldestFirst where totalBackupBytes > availableBackupBytes {
            try fileManager.removeItem(at: backup.url)
            totalBackupBytes -= backup.size
        }
    }

    private func removeTemporaryFiles() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try contents()
        where url.lastPathComponent.hasPrefix(Self.temporaryPrefix) {
            try fileManager.removeItem(at: url)
        }
    }

    private func contents() throws -> [URL] {
        try requireSafeDirectory(expectsExistingDirectory: true)
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
    }

    private func requireSafeDirectory(expectsExistingDirectory: Bool) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        guard !expectsExistingDirectory || exists,
              (!exists || isDirectory.boolValue) else {
            throw ActivityStoreError.unsafeStorage
        }
        guard exists else { return }

        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ActivityStoreError.unsafeStorage
        }
    }
}
