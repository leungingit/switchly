import CoreFoundation
import Foundation

enum MediaRemoteBudget {
    static let lineBytes = 12 * 1024 * 1024
    static let artworkBytes = 8 * 1024 * 1024
    static let readBytes = 64 * 1024
    static let startupSeconds: TimeInterval = 2
    static let terminationSeconds: TimeInterval = 1
}

enum MediaRemoteFailure: Error, Equatable {
    case lineTooLong, malformedEvent, missingFullSnapshot, truncatedLine
    case launchFailed, startupTimeout, pipeFailed, streamEnded, exited(Int32)
}

enum MediaRemoteField: String, CaseIterable {
    case bundleIdentifier, processIdentifier, title, artist, album, playing
    case duration, elapsedTime, playbackRate, timestamp
    case uniqueIdentifier, contentItemIdentifier, artworkData, artworkMimeType
}

enum MediaRemoteValue: Equatable {
    case string(String), number(Double), bool(Bool), null

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
}

struct MediaRemoteEvent: Equatable {
    let isDiff: Bool
    let fields: [MediaRemoteField: MediaRemoteValue]

    static func decode(_ data: Data) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "data",
              let diff = object["diff"] as? NSNumber,
              CFGetTypeID(diff) == CFBooleanGetTypeID(),
              let payload = object["payload"] as? [String: Any] else {
            throw MediaRemoteFailure.malformedEvent
        }
        var fields: [MediaRemoteField: MediaRemoteValue] = [:]
        for field in MediaRemoteField.allCases {
            guard let value = payload[field.rawValue] else { continue }
            if value is NSNull { fields[field] = .null; continue }
            switch field {
            case .playing:
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw MediaRemoteFailure.malformedEvent
                }
                fields[field] = .bool(value.boolValue)
            case .processIdentifier, .duration, .elapsedTime, .playbackRate:
                guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite else { throw MediaRemoteFailure.malformedEvent }
                fields[field] = .number(value.doubleValue)
            case .uniqueIdentifier:
                if let value = value as? String { fields[field] = .string(value) }
                else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                        value.doubleValue.isFinite, abs(value.doubleValue) <= 9_007_199_254_740_991,
                        value.doubleValue.rounded() == value.doubleValue {
                    fields[field] = .string(value.stringValue)
                } else { throw MediaRemoteFailure.malformedEvent }
            default:
                guard let value = value as? String else { throw MediaRemoteFailure.malformedEvent }
                fields[field] = .string(value)
            }
        }
        return Self(isDiff: diff.boolValue, fields: fields)
    }
}

/// 消费管道分片而非假定一次 read 等于一行；追加前检查上限。
struct MediaRemoteLineDecoder {
    private var pending = Data()
    private let limit: Int
    init(limit: Int = MediaRemoteBudget.lineBytes) { self.limit = limit }

    mutating func consume(_ data: Data, emit: (MediaRemoteEvent) throws -> Void) throws {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            let count = data.distance(from: start, to: end)
            guard count <= limit - pending.count else {
                pending.removeAll(keepingCapacity: false)
                throw MediaRemoteFailure.lineTooLong
            }
            pending.append(contentsOf: data[start..<end])
            guard let newline else { return }
            let line = pending
            pending = Data()
            try emit(MediaRemoteEvent.decode(line))
            start = data.index(after: newline)
        }
    }

    mutating func finish() throws {
        guard pending.isEmpty else {
            pending.removeAll(keepingCapacity: false)
            throw MediaRemoteFailure.truncatedLine
        }
    }
}
