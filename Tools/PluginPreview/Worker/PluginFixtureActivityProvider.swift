import Foundation

private struct PluginActivityFixtureCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct PluginPreviewActivityFixture: Decodable {
    static let maximumSessionCount = 100_000

    struct Session: Decodable {
        let id: UUID
        let bundleID: String
        let appName: String
        let start: Double
        let end: Double
        let seconds: Double
        let endReason: ActivityEndReason

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, bundleID, appName, start, end, seconds, endReason
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: PluginActivityFixtureCodingKey.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard Set(raw.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue)) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "activity session has unknown or missing fields")
                )
            }
            id = try container.decode(UUID.self, forKey: .id)
            bundleID = try container.decode(String.self, forKey: .bundleID)
            appName = try container.decode(String.self, forKey: .appName)
            start = try container.decode(Double.self, forKey: .start)
            end = try container.decode(Double.self, forKey: .end)
            seconds = try container.decode(Double.self, forKey: .seconds)
            endReason = try container.decode(ActivityEndReason.self, forKey: .endReason)
        }
    }

    let schemaVersion: Int
    let sessions: [Session]
    let snapshots: [UUID]?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sessions, snapshots
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: PluginActivityFixtureCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.stringValue))),
              container.contains(.schemaVersion), container.contains(.sessions) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "activity fixture has unknown or missing fields")
            )
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sessions = try container.decode([Session].self, forKey: .sessions)
        snapshots = container.contains(.snapshots)
            ? try container.decode([UUID].self, forKey: .snapshots)
            : nil
    }

    func validated() throws -> PluginPreviewActivityFixture {
        guard schemaVersion == 1,
              sessions.count <= Self.maximumSessionCount,
              Set(sessions.map(\.id)).count == sessions.count,
              Set(snapshots ?? []).count == (snapshots ?? []).count,
              sessions.allSatisfy({
                  !$0.bundleID.isEmpty && !$0.appName.isEmpty
                  && $0.bundleID.utf8.count <= 255 && $0.appName.utf8.count <= 255
                  && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end
                  && $0.seconds.isFinite && $0.seconds >= 0
              }) else {
            throw PluginPreviewWorkerFailure.invalidFixture
        }
        return self
    }
}

private enum PluginFixtureActivityError: Error {
    case invalidQuery
    case staleCursor
}

/// Pure in-memory activity source for Preview/Worker. It has no store,
/// tracking service, filesystem access, or snapshot/image resolver.
final class PluginFixtureActivityProvider: PluginActivityProviding, @unchecked Sendable {
    private let sessions: [ActivitySession]
    private let availableFrom: TimeInterval?
    private static let maximumPageSize = 100

    init(fixture: PluginPreviewActivityFixture) {
        sessions = fixture.sessions.map {
            ActivitySession(
                id: $0.id,
                bundleID: $0.bundleID,
                appName: $0.appName,
                start: Date(timeIntervalSince1970: $0.start),
                end: Date(timeIntervalSince1970: $0.end),
                seconds: $0.seconds,
                endReason: $0.endReason
            )
        }
        .sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
        availableFrom = sessions.map(\.start.timeIntervalSince1970).min()
    }

    func query(
        method: String,
        options: [String: Any],
        pluginID: String,
        snapshotsAllowed: Bool
    ) async throws -> [String: Any] {
        let range = try parseRange(options)
        let base: [String: Any] = [
            "revision": 1,
            "recording": false,
            "screenshotsEnabled": false,
            "availableFrom": availableFrom ?? NSNull()
        ]

        switch method {
        case "summary":
            try rejectUnknownOptions(options, allowed: ["from", "to", "groupBy", "timeZone"])
            let groupBy = options["groupBy"] as? String ?? "app"
            guard ["app", "hour", "day", "month"].contains(groupBy) else {
                throw PluginFixtureActivityError.invalidQuery
            }
            let timeZone: TimeZone
            if let identifier = options["timeZone"] as? String {
                guard let parsed = TimeZone(identifier: identifier) else {
                    throw PluginFixtureActivityError.invalidQuery
                }
                timeZone = parsed
            } else {
                timeZone = .current
            }
            let items = ActivityQuery.summary(
                sessions: sessions,
                from: range.from,
                to: range.to,
                groupBy: groupBy,
                timeZone: timeZone
            )
            guard items.count <= 1000 else { throw PluginFixtureActivityError.invalidQuery }
            return base.merging(["items": items]) { _, new in new }

        case "sessions":
            try rejectUnknownOptions(options, allowed: ["from", "to", "bundleID", "limit", "cursor"])
            let bundleID = try optionalString("bundleID", in: options)
            let filtered = sessions.filter {
                $0.start < range.to && $0.end > range.from
                    && (bundleID == nil || $0.bundleID == bundleID)
            }
            let page = try page(
                options: options,
                method: method,
                count: filtered.count,
                identity: [
                    "method": method,
                    "from": range.from.timeIntervalSince1970,
                    "to": range.to.timeIntervalSince1970,
                    "bundleID": bundleID ?? ""
                ]
            )
            let items = filtered[page.range].map { session -> [String: Any] in
                let start = max(range.from, session.start)
                let end = min(range.to, session.end)
                let wallSeconds = session.end.timeIntervalSince(session.start)
                return [
                    "id": session.id.uuidString,
                    "bundleID": session.bundleID,
                    "appName": session.appName,
                    "start": start.timeIntervalSince1970,
                    "end": end.timeIntervalSince1970,
                    "seconds": session.seconds * end.timeIntervalSince(start) / max(0.001, wallSeconds),
                    "endReason": session.endReason.rawValue
                ]
            }
            return base.merging([
                "items": items,
                "nextCursor": page.nextCursor ?? NSNull()
            ]) { _, new in new }

        case "snapshots":
            try rejectUnknownOptions(options, allowed: ["from", "to", "bundleID", "limit", "cursor"])
            guard snapshotsAllowed else { throw PluginFixtureActivityError.invalidQuery }
            _ = try page(
                options: options,
                method: method,
                count: 0,
                identity: [
                    "method": method,
                    "from": range.from.timeIntervalSince1970,
                    "to": range.to.timeIntervalSince1970,
                    "bundleID": (try optionalString("bundleID", in: options)) ?? ""
                ]
            )
            return base.merging([
                "items": [[String: Any]](),
                "nextCursor": NSNull()
            ]) { _, new in new }

        default:
            throw PluginFixtureActivityError.invalidQuery
        }
    }

    private func parseRange(_ options: [String: Any]) throws -> (from: Date, to: Date) {
        guard let rawFrom = options["from"] as? Double,
              let rawTo = options["to"] as? Double,
              rawFrom.isFinite, rawTo.isFinite,
              rawFrom >= 0, rawFrom < rawTo,
              rawTo - rawFrom <= 400 * 86_400 else {
            throw PluginFixtureActivityError.invalidQuery
        }
        return (
            Date(timeIntervalSince1970: rawFrom),
            Date(timeIntervalSince1970: rawTo)
        )
    }

    private func page(
        options: [String: Any],
        method: String,
        count: Int,
        identity: [String: Any]
    ) throws -> (range: Range<Int>, nextCursor: String?) {
        let maximum = method == "snapshots" ? 6 : Self.maximumPageSize
        let limit = options["limit"] as? Double ?? Double(maximum)
        guard limit.isFinite, limit >= 1, limit <= Double(maximum),
              limit.rounded() == limit else {
            throw PluginFixtureActivityError.invalidQuery
        }
        var identity = identity
        identity["limit"] = limit
        let signature = try JSONSerialization.data(withJSONObject: identity, options: .sortedKeys)
            .base64EncodedString()
        var offset = 0
        if let cursor = options["cursor"], !(cursor is NSNull) {
            guard let cursor = cursor as? String else {
                throw PluginFixtureActivityError.invalidQuery
            }
            let pieces = cursor.split(separator: ":", maxSplits: 2).map(String.init)
            guard pieces.count == 3, pieces[0] == "1", pieces[2] == signature,
                  let parsed = Int(pieces[1]), parsed >= 0, parsed <= count else {
                throw PluginFixtureActivityError.staleCursor
            }
            offset = parsed
        }
        let upper = min(count, offset + Int(limit))
        let next = upper < count ? "1:\(upper):\(signature)" : nil
        return (offset..<upper, next)
    }

    private func optionalString(_ key: String, in options: [String: Any]) throws -> String? {
        guard let value = options[key], !(value is NSNull) else { return nil }
        guard let string = value as? String, !string.isEmpty else {
            throw PluginFixtureActivityError.invalidQuery
        }
        return string
    }

    private func rejectUnknownOptions(_ options: [String: Any], allowed: Set<String>) throws {
        guard Set(options.keys).isSubset(of: allowed) else {
            throw PluginFixtureActivityError.invalidQuery
        }
    }
}
