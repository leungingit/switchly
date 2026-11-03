import Foundation

/// 协议错误；描述固定且不包含帧内容，可安全写入日志。
enum PluginPreviewFrameError: Error, Equatable, LocalizedError {
    case truncated
    case emptyFrame
    case invalidUTF8
    case invalidJSON
    case invalidPayload
    case frameTooLarge
    case trailingBytes
    case unsupportedProtocolVersion(found: Int)
    case streamFinished

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "preview frame is truncated"
        case .emptyFrame:
            return "preview frame is empty"
        case .invalidUTF8:
            return "preview frame is not valid UTF-8"
        case .invalidJSON:
            return "preview frame is not valid JSON"
        case .invalidPayload:
            return "preview frame does not match the protocol schema"
        case .frameTooLarge:
            return "preview frame exceeds the byte budget"
        case .trailingBytes:
            return "preview frame has bytes after its declared length"
        case .unsupportedProtocolVersion(let found):
            return "unsupported preview protocol version \(found)"
        case .streamFinished:
            return "preview frame stream is already finished"
        }
    }
}

/// 每个预览帧携带的带版本 JSON 对象。
struct PluginPreviewFrame<Payload: Codable> {
    static var protocolVersion: Int { PluginPreviewFrameCodec.protocolVersion }

    let protocolVersion: Int
    let type: String
    let generation: UInt64
    let requestID: UInt64
    let payload: Payload

    init(type: String, generation: UInt64, requestID: UInt64, payload: Payload) {
        self.protocolVersion = Self.protocolVersion
        self.type = type
        self.generation = generation
        self.requestID = requestID
        self.payload = payload
    }
}

extension PluginPreviewFrame: Codable {}
extension PluginPreviewFrame: Equatable where Payload: Equatable {}

/// 编解码单个带长度前缀的 UTF-8 JSON 协议帧。
enum PluginPreviewFrameCodec {
    static let protocolVersion = 1
    static let lengthPrefixBytes = 4
    static let maxFrameBytes = PluginPackageValidator.maxPackageBytes
    static let maxWireBytes = lengthPrefixBytes + maxFrameBytes

    private struct Header: Decodable {
        let protocolVersion: Int
    }

    static func encode<Payload: Codable>(_ frame: PluginPreviewFrame<Payload>) throws -> Data {
        guard frame.protocolVersion == protocolVersion else {
            throw PluginPreviewFrameError.unsupportedProtocolVersion(found: frame.protocolVersion)
        }

        let json: Data
        do {
            json = try JSONEncoder().encode(frame)
        } catch {
            throw PluginPreviewFrameError.invalidPayload
        }
        guard json.count <= maxFrameBytes else {
            throw PluginPreviewFrameError.frameTooLarge
        }

        var wire = Data(capacity: lengthPrefixBytes + json.count)
        appendBigEndianLength(UInt32(json.count), to: &wire)
        wire.append(json)
        return wire
    }

    static func decode<Payload: Codable>(
        _ payloadType: Payload.Type,
        from wire: Data
    ) throws -> PluginPreviewFrame<Payload> {
        let json = try jsonBytes(from: wire)
        do {
            _ = try JSONSerialization.jsonObject(with: json, options: [])
        } catch {
            throw PluginPreviewFrameError.invalidJSON
        }

        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: json)
        } catch {
            throw PluginPreviewFrameError.invalidPayload
        }
        guard header.protocolVersion == protocolVersion else {
            throw PluginPreviewFrameError.unsupportedProtocolVersion(found: header.protocolVersion)
        }

        let frame: PluginPreviewFrame<Payload>
        do {
            frame = try JSONDecoder().decode(PluginPreviewFrame<Payload>.self, from: json)
        } catch {
            throw PluginPreviewFrameError.invalidPayload
        }
        return frame
    }

    private static func jsonBytes(from wire: Data) throws -> Data {
        guard wire.count >= lengthPrefixBytes else {
            throw PluginPreviewFrameError.truncated
        }
        let frameBytes = readBigEndianLength(from: wire)
        guard frameBytes > 0 else {
            throw PluginPreviewFrameError.emptyFrame
        }
        guard UInt64(frameBytes) <= UInt64(maxFrameBytes) else {
            throw PluginPreviewFrameError.frameTooLarge
        }

        let expectedWireBytes = lengthPrefixBytes + Int(frameBytes)
        guard wire.count >= expectedWireBytes else {
            throw PluginPreviewFrameError.truncated
        }
        guard wire.count == expectedWireBytes else {
            throw PluginPreviewFrameError.trailingBytes
        }

        let json = wire.subdata(in: lengthPrefixBytes..<expectedWireBytes)
        guard String(data: json, encoding: .utf8) != nil else {
            throw PluginPreviewFrameError.invalidUTF8
        }
        return json
    }

    private static func readBigEndianLength(from wire: Data) -> UInt32 {
        wire.prefix(lengthPrefixBytes).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    private static func appendBigEndianLength(_ length: UInt32, to data: inout Data) {
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
    }
}

/// 增量解码字节流，最多保留一个未完成帧。
struct PluginPreviewFrameStreamDecoder<Payload: Codable> {
    private var buffer = Data()
    private var expectedWireBytes: Int?
    private var finished = false

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ bytes: Data) throws -> [PluginPreviewFrame<Payload>] {
        guard !finished else {
            throw PluginPreviewFrameError.streamFinished
        }

        var frames: [PluginPreviewFrame<Payload>] = []
        var offset = 0
        while offset < bytes.count {
            if expectedWireBytes == nil {
                let prefixRemaining = PluginPreviewFrameCodec.lengthPrefixBytes - buffer.count
                let count = min(prefixRemaining, bytes.count - offset)
                buffer.append(bytes.subdata(in: offset..<(offset + count)))
                offset += count

                guard buffer.count == PluginPreviewFrameCodec.lengthPrefixBytes else {
                    continue
                }
                let frameBytes = buffer.reduce(UInt32(0)) { partial, byte in
                    (partial << 8) | UInt32(byte)
                }
                guard frameBytes > 0 else {
                    throw PluginPreviewFrameError.emptyFrame
                }
                guard UInt64(frameBytes) <= UInt64(PluginPreviewFrameCodec.maxFrameBytes) else {
                    throw PluginPreviewFrameError.frameTooLarge
                }
                expectedWireBytes = PluginPreviewFrameCodec.lengthPrefixBytes + Int(frameBytes)
            }

            guard let expectedWireBytes else {
                continue
            }
            let frameRemaining = expectedWireBytes - buffer.count
            let count = min(frameRemaining, bytes.count - offset)
            buffer.append(bytes.subdata(in: offset..<(offset + count)))
            offset += count

            if buffer.count == expectedWireBytes {
                let frame = buffer
                buffer.removeAll(keepingCapacity: true)
                self.expectedWireBytes = nil
                frames.append(try PluginPreviewFrameCodec.decode(Payload.self, from: frame))
            }
        }
        return frames
    }

    mutating func finish() throws {
        guard !finished else {
            throw PluginPreviewFrameError.streamFinished
        }
        finished = true
        guard buffer.isEmpty else {
            throw PluginPreviewFrameError.truncated
        }
    }
}
