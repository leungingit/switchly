//
//  ActivityStoreTests.swift
//  SwitchlyTests
//
//  Regression coverage for the local activity timeline store.
//

import XCTest
@testable import Switchly

final class ActivityStoreTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private final class TestClock: @unchecked Sendable {
        var value: Date

        init(_ value: Date) {
            self.value = value
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchlyActivityStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func session(
        id: UUID = UUID(),
        bundleID: String = "com.example.app",
        appName: String = "Example",
        start: Date,
        end: Date,
        seconds: Double? = nil,
        reason: ActivityEndReason = .checkpoint
    ) -> ActivitySession {
        ActivitySession(
            id: id,
            bundleID: bundleID,
            appName: appName,
            start: start,
            end: end,
            seconds: seconds ?? end.timeIntervalSince(start),
            endReason: reason
        )
    }

    private func createSparseFile(
        at url: URL,
        size: Int64,
        prefix: Data = Data()
    ) throws {
        try prefix.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    private func activityFileData(
        schemaVersion: Int = ActivityStore.schemaVersion,
        bundleID: String = "com.example.app"
    ) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "retentionDays": ActivityStore.defaultRetentionDays,
            "sessions": [[
                "id": "00000000-0000-0000-0000-000000000001",
                "bundleID": bundleID,
                "appName": "Example",
                "start": baseDate.timeIntervalSince1970,
                "end": baseDate.addingTimeInterval(60).timeIntervalSince1970,
                "seconds": 60,
                "endReason": ActivityEndReason.checkpoint.rawValue
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func replacingFile(
        at url: URL,
        with data: Data,
        modificationDate: Date?
    ) throws {
        let replacement = url.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString)")
        try data.write(to: replacement)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: replacement.path
            )
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: url.path
            )
        }
    }

    private func modificationDate(of url: URL) throws -> Date? {
        try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    func testApplyUpsertsSortsStoresEpochDatesAndSecurePermissions() async throws {
        let directory = try temporaryDirectory()
        let clock = TestClock(baseDate)
        let store = ActivityStore(directory: directory, now: { clock.value })
        let generation = UUID()
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let later = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let updated = session(
            id: earlier,
            start: baseDate,
            end: baseDate.addingTimeInterval(120),
            seconds: 120,
            reason: .switched
        )

        try await store.begin(generation: generation)
        try await store.apply(
            [
                session(id: later, start: baseDate, end: baseDate.addingTimeInterval(30)),
                session(id: earlier, start: baseDate, end: baseDate.addingTimeInterval(60))
            ],
            generation: generation
        )
        try await store.apply([updated], generation: generation)

        let read = try await store.read(
            from: baseDate.addingTimeInterval(-1),
            to: baseDate.addingTimeInterval(121)
        )
        XCTAssertEqual(read, [updated, session(
            id: later,
            start: baseDate,
            end: baseDate.addingTimeInterval(30)
        )])

        let file = directory.appendingPathComponent("activity.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["retentionDays"] as? Int, 400)
        let encodedSessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let start = try XCTUnwrap(encodedSessions.first?["start"] as? NSNumber)
        XCTAssertEqual(start.doubleValue, baseDate.timeIntervalSince1970, accuracy: 0.001)

        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        ).intValue
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(directoryMode, 0o700)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("activity.json.tmp-") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testTruncateAfterClipsCrossingSessionsAndDropsLaterRecords() async throws {
        let directory = try temporaryDirectory()
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let firstID = UUID()
        let laterID = UUID()
        let cutoff = baseDate.addingTimeInterval(1_800)
        let corrected = session(
            id: firstID,
            start: baseDate,
            end: baseDate.addingTimeInterval(3_600),
            seconds: 1_800,
            reason: .checkpoint
        )

        try await store.begin(generation: generation)
        try await store.apply([corrected], generation: generation)
        try await store.apply(
            [
                session(
                    id: laterID,
                    start: cutoff.addingTimeInterval(100),
                    end: cutoff.addingTimeInterval(200)
                )
            ],
            truncateAfter: cutoff,
            generation: generation
        )

        let read = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(3_601)
        )
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, firstID)
        XCTAssertEqual(read[0].end, cutoff)
        XCTAssertEqual(read[0].seconds, 900, accuracy: 0.001)
        XCTAssertEqual(read[0].seconds, read[0].end.timeIntervalSince(read[0].start) / 2, accuracy: 0.001)
    }

    func testNewGenerationDiscardsLateWritesAndClearInvalidatesBeforeDiskRemoval() async throws {
        let directory = try temporaryDirectory()
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let firstGeneration = UUID()
        let competingGeneration = UUID()
        let nextGeneration = UUID()
        let record = session(
            id: UUID(),
            start: baseDate,
            end: baseDate.addingTimeInterval(10)
        )

        try await store.begin(generation: firstGeneration)
        try await store.begin(generation: competingGeneration)
        try await store.apply([record], generation: firstGeneration)

        do {
            try await store.apply([record], generation: competingGeneration)
            XCTFail("A competing generation must not write")
        } catch ActivityStoreError.staleGeneration {}

        try await store.clear(generation: firstGeneration)
        do {
            try await store.apply([record], generation: firstGeneration)
            XCTFail("The cleared generation must not write")
        } catch ActivityStoreError.staleGeneration {}

        try await store.begin(generation: nextGeneration)
        try await store.apply([record], generation: nextGeneration)
        let read = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(11)
        )
        XCTAssertEqual(read, [record])
    }

    func testClearRemovesLiveCorruptAndTemporaryFilesWithoutTouchingSibling() async throws {
        let directory = try temporaryDirectory()
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let live = directory.appendingPathComponent("activity.json")
        let corrupt = directory.appendingPathComponent("activity.corrupt-\(UUID().uuidString).json")
        let temporary = directory.appendingPathComponent("activity.json.tmp-\(UUID().uuidString)")
        let sibling = directory.deletingLastPathComponent()
            .appendingPathComponent("activity-store-outside-\(UUID().uuidString)")
        try Data("malformed".utf8).write(to: live)
        try Data("backup".utf8).write(to: corrupt)
        try Data("temporary".utf8).write(to: temporary)
        try Data("outside".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }

        try await store.begin(generation: generation)
        try await store.clear(generation: generation)

        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testReadRejectsExpiredRetentionAndInvalidQueryRanges() async throws {
        let directory = try temporaryDirectory()
        let clock = TestClock(baseDate)
        let store = ActivityStore(directory: directory, now: { clock.value })
        let generation = UUID()
        let recent = session(
            id: UUID(),
            start: baseDate.addingTimeInterval(-86_400),
            end: baseDate.addingTimeInterval(-86_300)
        )

        try await store.begin(generation: generation)
        try await store.apply([recent], retentionDays: 7, generation: generation)
        clock.value = baseDate.addingTimeInterval(7 * 86_400)

        let read = try await store.read(
            from: baseDate.addingTimeInterval(-86_400),
            to: baseDate.addingTimeInterval(-86_299)
        )
        XCTAssertTrue(read.isEmpty)

        do {
            _ = try await store.read(from: baseDate, to: baseDate)
            XCTFail("from must be earlier than to")
        } catch ActivityStoreError.invalidDateRange {}

        do {
            _ = try await store.read(
                from: baseDate,
                to: baseDate.addingTimeInterval(401 * 86_400)
            )
            XCTFail("Queries must be capped at 400 days")
        } catch ActivityStoreError.queryRangeTooLong {}

        for days in [0, 2, 401] {
            do {
                try await store.prune(retentionDays: days)
                XCTFail("Unsupported retention period: \(days)")
            } catch ActivityStoreError.invalidRetentionDays {}
        }
    }

    func testCorruptFileMovesToRetainedBackupAndExpires() async throws {
        let directory = try temporaryDirectory()
        let clock = TestClock(baseDate)
        let live = directory.appendingPathComponent("activity.json")
        try Data("{not-json".utf8).write(to: live)
        let store = ActivityStore(directory: directory, now: { clock.value })

        let read = try await store.read(
            from: baseDate.addingTimeInterval(-86_400),
            to: baseDate.addingTimeInterval(1)
        )
        XCTAssertTrue(read.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("activity.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        let backupMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(backupMode, 0o600)

        clock.value = baseDate.addingTimeInterval(2 * 86_400)
        try await store.prune(retentionDays: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups[0].path))
    }

    func testCorruptBackupsShareTheLiveByteBudgetAndEvictOldestFirst() async throws {
        let directory = try temporaryDirectory()
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let live = directory.appendingPathComponent("activity.json")
        let oldest = directory.appendingPathComponent("activity.corrupt-oldest.json")
        let newest = directory.appendingPathComponent("activity.corrupt-newest.json")
        let backupSize = Int64(33 * 1024 * 1024)

        try await store.begin(generation: generation)
        try await store.apply(
            [session(
                id: UUID(),
                start: baseDate,
                end: baseDate.addingTimeInterval(10)
            )],
            generation: generation
        )
        try createSparseFile(at: oldest, size: backupSize)
        try createSparseFile(at: newest, size: backupSize)
        try FileManager.default.setAttributes(
            [.modificationDate: baseDate.addingTimeInterval(-120)],
            ofItemAtPath: oldest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: baseDate.addingTimeInterval(-60)],
            ofItemAtPath: newest.path
        )

        _ = try await store.read(
            from: baseDate.addingTimeInterval(-1),
            to: baseDate.addingTimeInterval(11)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        let liveSize = try XCTUnwrap(
            live.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let newestSize = try XCTUnwrap(
            newest.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertLessThanOrEqual(
            Int64(liveSize) + Int64(newestSize),
            Int64(ActivityStore.maximumEncodedBytes)
        )
    }

    func testWriteReservesByteBudgetForTheNewLiveFile() async throws {
        let directory = try temporaryDirectory()
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let live = directory.appendingPathComponent("activity.json")
        let backup = directory.appendingPathComponent("activity.corrupt-full.json")

        try createSparseFile(
            at: backup,
            size: Int64(ActivityStore.maximumEncodedBytes)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: baseDate],
            ofItemAtPath: backup.path
        )
        try await store.begin(generation: generation)
        try await store.apply(
            [session(
                id: UUID(),
                start: baseDate,
                end: baseDate.addingTimeInterval(10)
            )],
            generation: generation
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(contents.contains {
            $0.lastPathComponent.hasPrefix(ActivityStore.temporaryPrefix)
        })
    }

    func testDecodeCacheDetectsSameSizeExternalReplacement() async throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("activity.json")
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let original = try activityFileData(bundleID: "com.example.a")
        let replacement = try activityFileData(bundleID: "com.example.b")

        try original.write(to: live)
        let originalDate = baseDate.addingTimeInterval(-60)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: live.path
        )
        let first = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(61)
        )
        XCTAssertEqual(first.first?.bundleID, "com.example.a")

        XCTAssertEqual(replacement.count, original.count)
        try replacingFile(
            at: live,
            with: replacement,
            modificationDate: originalDate
        )
        XCTAssertEqual(try modificationDate(of: live), originalDate)

        let second = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(61)
        )
        XCTAssertEqual(second.first?.bundleID, "com.example.b")
    }

    func testDecodeCacheDoesNotHideAnAtomicallyReplacedNewerSchema() async throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("activity.json")
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let newerSchema = try activityFileData(
            schemaVersion: ActivityStore.schemaVersion + 1
        )
        var currentSchema = try activityFileData()
        currentSchema.append(Data(
            repeating: 0x20,
            count: newerSchema.count - currentSchema.count
        ))
        XCTAssertEqual(currentSchema.count, newerSchema.count)

        try currentSchema.write(to: live)
        let originalDate = baseDate.addingTimeInterval(-60)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: live.path
        )
        _ = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(61)
        )

        try replacingFile(
            at: live,
            with: newerSchema,
            modificationDate: originalDate
        )
        do {
            _ = try await store.read(
                from: baseDate,
                to: baseDate.addingTimeInterval(61)
            )
            XCTFail("The newer schema must bypass and evict the decoded cache")
        } catch let ActivityStoreError.unsupportedSchemaVersion(version) {
            XCTAssertEqual(version, ActivityStore.schemaVersion + 1)
        }
        XCTAssertEqual(try Data(contentsOf: live), newerSchema)
    }

    func testStoreMutationsInvalidateDecodedCache() async throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("activity.json")
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let initial = session(
            id: id,
            start: baseDate,
            end: baseDate.addingTimeInterval(10)
        )
        let updated = session(
            id: id,
            start: baseDate,
            end: baseDate.addingTimeInterval(20),
            seconds: 20,
            reason: .switched
        )

        try await store.begin(generation: generation)
        try await store.apply([initial], generation: generation)
        _ = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(11)
        )
        try await store.apply([updated], generation: generation)
        let afterWrite = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(21)
        )
        XCTAssertEqual(afterWrite, [updated])

        try Data("{not-json".utf8).write(to: live)
        let afterQuarantine = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(21)
        )
        XCTAssertTrue(afterQuarantine.isEmpty)

        try await store.apply([initial], generation: generation)
        _ = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(11)
        )
        try await store.clear(generation: generation)

        try activityFileData().write(to: live)
        let afterClear = try await store.read(
            from: baseDate,
            to: baseDate.addingTimeInterval(61)
        )
        XCTAssertEqual(afterClear.first?.bundleID, "com.example.app")
        XCTAssertEqual(afterClear.first?.start, baseDate)
    }

    func testOversizedLiveFileFailsBeforeReadingOrQuarantiningIt() async throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("activity.json")
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let prefix = Data(
            #"{"schemaVersion":99,"retentionDays":400,"sessions":[]}"#.utf8
        )
        let size = Int64(ActivityStore.maximumEncodedBytes) + 1
        try createSparseFile(at: live, size: size, prefix: prefix)
        try await store.begin(generation: generation)

        for operation in [0, 1] {
            do {
                if operation == 0 {
                    _ = try await store.read(
                        from: baseDate,
                        to: baseDate.addingTimeInterval(1)
                    )
                } else {
                    try await store.apply([], generation: generation)
                }
                XCTFail("An oversized file must be rejected before allocation")
            } catch ActivityStoreError.encodedDataTooLarge {}
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertEqual(
            try live.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            Int(size)
        )
        let handle = try FileHandle(forReadingFrom: live)
        XCTAssertEqual(
            try handle.read(upToCount: prefix.count),
            prefix
        )
        try handle.close()
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(ActivityStore.corruptPrefix)
        }
        XCTAssertTrue(backups.isEmpty)
    }

    func testPrunePersistsRetentionAndRemovesExpiredSessions() async throws {
        let directory = try temporaryDirectory()
        let clock = TestClock(baseDate)
        let store = ActivityStore(directory: directory, now: { clock.value })
        let generation = UUID()
        let expired = session(
            id: UUID(),
            start: baseDate.addingTimeInterval(-2 * 86_400),
            end: baseDate.addingTimeInterval(-86_400)
        )
        let retained = session(
            id: UUID(),
            start: baseDate.addingTimeInterval(2 * 86_400),
            end: baseDate.addingTimeInterval(2 * 86_400 + 3_600)
        )

        try await store.begin(generation: generation)
        try await store.apply(
            [expired, retained],
            retentionDays: 7,
            generation: generation
        )
        clock.value = baseDate.addingTimeInterval(2 * 86_400 + 1_800)
        try await store.prune(retentionDays: 1)

        let read = try await store.read(
            from: baseDate.addingTimeInterval(2 * 86_400),
            to: baseDate.addingTimeInterval(2 * 86_400 + 3_601)
        )
        XCTAssertEqual(read, [retained])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: directory.appendingPathComponent("activity.json")
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(object["retentionDays"] as? Int, 1)
    }

    func testNewerSchemaFailsWithoutOverwritingTheUnknownData() async throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("activity.json")
        let original = Data(
            #"{"schemaVersion":99,"retentionDays":400,"sessions":[]}"#.utf8
        )
        try original.write(to: live)
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()

        do {
            try await store.begin(generation: generation)
            try await store.apply([], generation: generation)
            XCTFail("A newer schema must not be overwritten")
        } catch let ActivityStoreError.unsupportedSchemaVersion(version) {
            XCTAssertEqual(version, 99)
        }
        XCTAssertEqual(try Data(contentsOf: live), original)
    }

    func testApplyEvictsOldestSessionBeyondHardLimit() async throws {
        let directory = try temporaryDirectory()
        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        let sessions = (0...100_000).map { offset in
            let start = baseDate.addingTimeInterval(Double(offset))
            return session(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset))!,
                start: start,
                end: start.addingTimeInterval(0.5)
            )
        }

        try await store.begin(generation: generation)
        try await store.apply(sessions, generation: generation)
        let read = try await store.read(from: baseDate, to: baseDate.addingTimeInterval(100_002))
        XCTAssertEqual(read.count, 100_000)
        XCTAssertEqual(read.first?.start, baseDate.addingTimeInterval(1))
        XCTAssertEqual(read.last?.start, baseDate.addingTimeInterval(100_000))
    }

    func testSymlinkStorageDirectoryIsRejectedWithoutTouchingItsTarget() async throws {
        let directory = try temporaryDirectory()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchlyActivityStoreTarget-\(UUID().uuidString)")
        let marker = target.appendingPathComponent("outside-marker")
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: target)
        }

        try fileManager.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("outside".utf8).write(to: marker)
        try fileManager.removeItem(at: directory)
        try fileManager.createSymbolicLink(
            atPath: directory.path,
            withDestinationPath: target.path
        )

        let store = ActivityStore(directory: directory, now: { self.baseDate })
        let generation = UUID()
        try await store.begin(generation: generation)

        do {
            try await store.apply(
                [
                    session(
                        id: UUID(),
                        start: baseDate,
                        end: baseDate.addingTimeInterval(10)
                    )
                ],
                generation: generation
            )
            XCTFail("A symlink storage directory must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .unsafeStorage)
        }

        do {
            try await store.clear(generation: generation)
            XCTFail("clear must reject a symlink storage directory")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .unsafeStorage)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
    }
}
