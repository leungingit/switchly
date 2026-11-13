import Foundation

/// 通用时间线条目；时间和内容分开，使宿主统一绘制时间轴。
struct PluginTimelineItem: Equatable, Decodable {
    let timestamp: Double
    let content: PluginUINode

    private enum CodingKeys: String, CodingKey { case timestamp, content }

    init(timestamp: Double, content: PluginUINode) {
        self.timestamp = timestamp; self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Double.self, forKey: .timestamp)
        guard timestamp.isFinite, timestamp >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container,
                                                  debugDescription: "timeline timestamp must be finite and nonnegative")
        }
        self.timestamp = timestamp
        content = try container.decode(PluginUINode.self, forKey: .content)
    }
}
