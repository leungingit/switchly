import Foundation

enum ActivityEndReason: String, Codable, Sendable {
    case checkpoint
    case switched
    case disabled
    case idle
    case blocked
    case terminated
    case clockChanged
}

struct ActivitySession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let bundleID: String
    let appName: String
    let start: Date
    let end: Date
    let seconds: Double
    let endReason: ActivityEndReason
}

enum ActivityBlocker: Hashable, Sendable {
    case locked
    case sleeping
    case inactiveSession
}
