import Foundation

/// One `console.*` call made by a plugin, kept in a small in-memory ring so a debugging
/// front end (the preview app) can ask for it. Nothing is written or sent unless asked.
struct PluginConsoleLine: Codable, Equatable, Sendable {
    let level: String
    let message: String
    let time: Double
}
