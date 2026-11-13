import AppKit
import CryptoKit

@MainActor
final class ActivityDataProvider: PluginActivityProviding, PluginActivityImageResolving {
    private struct Reference {
        let snapshotID: UUID
        let pluginID: String
        let generation: UUID
        let validity: PluginActivityReadValidity
        let expires: Date
    }
    nonisolated let validity: PluginActivityValidityGate
    private let tracking: ActivityTrackingService
    private let authorized: (String, PluginCapability) -> Bool
    private var references: [String: Reference] = [:]
    private var authorizationObserver: NSObjectProtocol?
    private var authorizationGeneration = UUID()

    init(tracking: ActivityTrackingService, authorized: @escaping (String, PluginCapability) -> Bool) {
        self.tracking = tracking; self.authorized = authorized
        self.validity = tracking.validity
        let gate = tracking.validity
        authorizationObserver = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            gate.invalidate()
            Task { @MainActor in self?.clearReferenceCache() }
        }
    }
    deinit { if let authorizationObserver { NotificationCenter.default.removeObserver(authorizationObserver) } }
    nonisolated func readValidity() -> PluginActivityReadValidity { validity.capture() }
    func invalidateAuthorization() { validity.invalidate(); clearReferenceCache() }
    private func clearReferenceCache() { authorizationGeneration = UUID(); references.removeAll() }

    func query(method: String, options: [String: Any], pluginID: String, snapshotsAllowed: Bool) async throws -> [String: Any] {
        guard authorized(pluginID, .activityRead), !tracking.isClearing else { throw ActivityDataError.denied }
        guard let from = options["from"] as? Double, let to = options["to"] as? Double,
              from.isFinite, to.isFinite, from >= 0, from < to, to - from <= 400 * 86400 else { throw ActivityDataError.invalidRange }
        let token = tracking.generation, authorizationToken = authorizationGeneration
        await tracking.flushAndWait()
        let revision = tracking.revision
        let start = Date(timeIntervalSince1970: from), end = Date(timeIntervalSince1970: to)
        let rows = try await tracking.store.read(from: start, to: end)
        let availableFrom = try await tracking.store.availableFrom(retentionDays: tracking.settings.resolvedRetentionDays)
        try Task.checkCancellation()
        guard tracking.generation == token, authorized(pluginID, .activityRead), !tracking.isClearing else { throw ActivityDataError.denied }
        var result: [String: Any]
        switch method {
        case "summary":
            let group = options["groupBy"] as? String ?? "app"
            guard ["app", "hour", "day", "month"].contains(group) else { throw ActivityDataError.invalidRange }
            let zone: TimeZone
            if let name = options["timeZone"] as? String { guard let value = TimeZone(identifier: name) else { throw ActivityDataError.invalidRange }; zone = value }
            else { zone = .current }
            let items = await Task.detached(priority: .utility) { ActivityQuery.summary(sessions: rows, from: start, to: end, groupBy: group, timeZone: zone) }.value
            guard items.count <= 1000 else { throw ActivityDataError.tooLarge }
            result = ["items": items, "availableFrom": availableFrom?.timeIntervalSince1970 as Any? ?? NSNull(),
                      "recording": tracking.settings.enabled, "screenshotsEnabled": tracking.settings.screenshotsEnabled, "revision": revision]
        case "sessions":
            let filtered = rows.filter { options["bundleID"] as? String == nil || $0.bundleID == options["bundleID"] as? String }
            let page = try await pageBounds(options: options, revision: revision, items: filtered, maximum: 100, method: method)
            let items = filtered[page.range].map { row -> [String: Any] in
                let a = max(row.start, start), b = min(row.end, end)
                return ["id": row.id.uuidString, "bundleID": row.bundleID, "appName": row.appName,
                        "start": a.timeIntervalSince1970, "end": b.timeIntervalSince1970,
                        "seconds": row.seconds * b.timeIntervalSince(a) / max(0.001, row.end.timeIntervalSince(row.start)), "endReason": row.endReason.rawValue]
            }
            result = ["items": items, "nextCursor": page.next as Any? ?? NSNull(), "revision": revision]
        case "snapshots":
            guard snapshotsAllowed, authorized(pluginID, .activitySnapshots) else { throw ActivityDataError.denied }
            let entries = try await tracking.snapshots.list(from: start, to: end, retentionDays: tracking.settings.resolvedScreenshotRetentionDays)
                .filter { options["bundleID"] as? String == nil || $0.bundleID == options["bundleID"] as? String }
            let page = try await pageBounds(options: options, revision: revision, items: entries, maximum: 6, method: method)
            references = references.filter { $0.value.expires > Date() && $0.value.generation == token }
            if references.count > 120 { references.removeAll() }
            var items: [[String: Any]] = []
            for entry in entries[page.range] {
                let ref = UUID().uuidString
                references[ref] = Reference(snapshotID: entry.id, pluginID: pluginID, generation: token, validity: validity.capture(), expires: Date().addingTimeInterval(120))
                items.append(["ref": ref, "capturedAt": entry.capturedAt.timeIntervalSince1970,
                              "bundleID": entry.bundleID, "sessionID": entry.sessionID.uuidString])
            }
            result = ["items": items, "nextCursor": page.next as Any? ?? NSNull(), "revision": revision]
        default: throw ActivityDataError.invalidRange
        }
        try Task.checkCancellation()
        guard token == tracking.generation, authorizationToken == authorizationGeneration, authorized(pluginID, .activityRead), method != "snapshots" || authorized(pluginID, .activitySnapshots) else { throw ActivityDataError.denied }
        guard try JSONSerialization.data(withJSONObject: result).count <= 1024 * 1024 else { throw ActivityDataError.tooLarge }
        return result
    }
    func image(reference: String, pluginID: String) async -> NSImage? {
        guard authorized(pluginID, .activityRead), authorized(pluginID, .activitySnapshots),
              let ref = references[reference], ref.pluginID == pluginID, ref.expires > Date(), ref.validity.isCurrent(), ref.generation == tracking.generation else { return nil }
        let authorizationToken = authorizationGeneration
        let image = try? await tracking.snapshots.image(id: ref.snapshotID, retentionDays: tracking.settings.resolvedScreenshotRetentionDays)
        guard ref.validity.isCurrent(), ref.generation == tracking.generation, authorizationToken == authorizationGeneration, references[reference] != nil, !tracking.isClearing, authorized(pluginID, .activityRead), authorized(pluginID, .activitySnapshots) else { return nil }
        return image
    }
    private func pageBounds<Item: Encodable & Sendable>(options: [String: Any], revision: Int, items: [Item], maximum: Int, method: String) async throws -> (range: Range<Int>, next: String?) {
        let requested = options["limit"] as? Double ?? Double(maximum)
        guard requested.isFinite, requested >= 1, requested <= Double(maximum), requested.rounded() == requested else { throw ActivityDataError.invalidRange }
        // 尾部追加不改变已读历史；查询、代次或已读前缀变化仍拒绝旧游标。
        let identity: [String: Any] = ["method": method, "from": options["from"]!, "to": options["to"]!, "bundleID": options["bundleID"] ?? "", "limit": requested, "generation": tracking.generation.uuidString]
        let signature = try JSONSerialization.data(withJSONObject: identity, options: .sortedKeys).base64EncodedString()
        var offset = 0
        if let cursor = options["cursor"] as? String {
            let pieces = cursor.split(separator: ":", maxSplits: 3).map(String.init)
            guard pieces.count == 4, Int(pieces[0]) != nil, pieces[3] == signature,
                  let parsed = Int(pieces[1]), parsed >= 0, parsed <= items.count else { throw ActivityDataError.staleCursor }
            let fingerprint = try await Self.prefixFingerprint(items, count: parsed)
            guard pieces[2] == fingerprint else { throw ActivityDataError.staleCursor }
            offset = parsed
        }
        let upper = min(items.count, offset + Int(requested))
        let fingerprint = upper < items.count ? try await Self.prefixFingerprint(items, count: upper) : nil
        return (offset..<upper, fingerprint.map { "\(revision):\(upper):\($0):\(signature)" })
    }

    private nonisolated static func prefixFingerprint<Item: Encodable & Sendable>(_ items: [Item], count: Int) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(Array(items.prefix(count)))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
