import Foundation

private struct TestPayload: Codable, Equatable {
    let marker: String
    let value: Int
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, _ message: String) throws {
    let value = try actual()
    guard value == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(value)")
    }
}

private func expectError<T>(_ expected: PluginPreviewFrameError, _ operation: () throws -> T) throws {
    do {
        _ = try operation()
    } catch let error as PluginPreviewFrameError {
        guard error == expected else {
            throw TestFailure(description: "expected \(expected), got \(error)")
        }
        return
    } catch {
        throw TestFailure(description: "expected \(expected), got unexpected error type")
    }
    throw TestFailure(description: "expected \(expected), but no error was thrown")
}

private func wire(json: String) -> Data {
    let body = Data(json.utf8)
    return wire(body: body)
}

private func wire(body: Data) -> Data {
    let length = UInt32(body.count)
    var result = Data([
        UInt8((length >> 24) & 0xff),
        UInt8((length >> 16) & 0xff),
        UInt8((length >> 8) & 0xff),
        UInt8(length & 0xff),
    ])
    result.append(body)
    return result
}

private func encodedLength(_ wire: Data) -> UInt32 {
    wire.prefix(4).reduce(UInt32(0)) { partial, byte in
        (partial << 8) | UInt32(byte)
    }
}

private struct Suite {
    private(set) var passed = 0
    private(set) var failed = 0

    mutating func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            let detail = (error as? TestFailure)?.description ?? "unexpected error"
            print("FAIL \(name): \(detail)")
        }
    }
}

@main
private enum PluginPreviewFrameCodecTests {
    static func main() {
        var suite = Suite()

        suite.run("budgets reuse the package validator constant") {
            try expectEqual(PluginPreviewFrameCodec.protocolVersion, 1, "protocol version")
            try expectEqual(
                PluginPreviewFrameCodec.maxFrameBytes,
                PluginPackageValidator.maxPackageBytes,
                "frame budget"
            )
            try expectEqual(PluginPreviewFrameCodec.maxWireBytes, 32 * 1024 * 1024 + 4, "wire budget")
        }

        suite.run("round trip preserves the versioned envelope and big-endian prefix") {
            let frame = PluginPreviewFrame(
                type: "render",
                generation: 7,
                requestID: 42,
                payload: TestPayload(marker: "ok", value: 9)
            )
            let bytes = try PluginPreviewFrameCodec.encode(frame)
            try expectEqual(encodedLength(bytes), UInt32(bytes.count - 4), "encoded body length")

            let decoded = try PluginPreviewFrameCodec.decode(TestPayload.self, from: bytes)
            try expectEqual(decoded, frame, "decoded frame")
            try expectEqual(decoded.protocolVersion, 1, "decoded protocol version")
        }

        suite.run("stream accepts arbitrary chunk boundaries and multiple frames") {
            let first = try PluginPreviewFrameCodec.encode(PluginPreviewFrame(
                type: "hello",
                generation: 1,
                requestID: 1,
                payload: TestPayload(marker: "first", value: 1)
            ))
            let second = try PluginPreviewFrameCodec.encode(PluginPreviewFrame(
                type: "render",
                generation: 2,
                requestID: 2,
                payload: TestPayload(marker: "second", value: 2)
            ))
            var combined = first
            combined.append(second)

            var decoder = PluginPreviewFrameStreamDecoder<TestPayload>()
            var decoded: [PluginPreviewFrame<TestPayload>] = []
            for byte in combined {
                decoded.append(contentsOf: try decoder.append(Data([byte])))
            }
            try decoder.finish()

            try expectEqual(decoded.map(\.type), ["hello", "render"], "frame order")
            try expectEqual(decoded.map(\.payload.marker), ["first", "second"], "payload order")
            try expectEqual(decoder.bufferedByteCount, 0, "buffer after complete frames")
        }

        suite.run("direct decoder rejects truncation, empty frames, and trailing bytes") {
            try expectError(.truncated) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: Data([0, 0, 0]))
            }
            try expectError(.truncated) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: Data([0, 0, 0, 5, 0x7b]))
            }
            try expectError(.emptyFrame) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: Data([0, 0, 0, 0]))
            }
            var trailing = wire(json: "{}")
            trailing.append(0x20)
            try expectError(.trailingBytes) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: trailing)
            }
        }

        suite.run("direct decoder rejects invalid UTF-8, JSON, and protocol versions") {
            try expectError(.invalidUTF8) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: wire(body: Data([0xff])))
            }
            try expectError(.invalidJSON) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: wire(json: "{"))
            }
            let unsupported = wire(json: #"{"protocolVersion":2,"type":"hello","generation":0,"requestID":1,"payload":{}}"#)
            try expectError(.unsupportedProtocolVersion(found: 2)) {
                try PluginPreviewFrameCodec.decode(TestPayload.self, from: unsupported)
            }
        }

        suite.run("oversized length is rejected before the body is buffered") {
            let oversized = UInt32(PluginPreviewFrameCodec.maxFrameBytes + 1)
            var bytes = Data([
                UInt8((oversized >> 24) & 0xff),
                UInt8((oversized >> 16) & 0xff),
                UInt8((oversized >> 8) & 0xff),
                UInt8(oversized & 0xff),
            ])
            bytes.append(Data(repeating: 0x41, count: 64 * 1024))

            var decoder = PluginPreviewFrameStreamDecoder<TestPayload>()
            try expectError(.frameTooLarge) {
                try decoder.append(bytes)
            }
            try expectEqual(decoder.bufferedByteCount, 4, "buffer retains only the prefix")
        }

        suite.run("stream reports empty and truncated frames at deterministic points") {
            var emptyDecoder = PluginPreviewFrameStreamDecoder<TestPayload>()
            try expectError(.emptyFrame) {
                try emptyDecoder.append(Data([0, 0, 0, 0]))
            }

            var truncatedDecoder = PluginPreviewFrameStreamDecoder<TestPayload>()
            let frames = try truncatedDecoder.append(Data([0, 0, 0, 5, 0x7b, 0x7d]))
            try expect(frames.isEmpty, "truncated frame must not be emitted")
            try expectError(.truncated) {
                try truncatedDecoder.finish()
            }
        }

        suite.run("errors do not echo frame content") {
            let sensitiveMarker = "sensitive-marker"
            do {
                _ = try PluginPreviewFrameCodec.decode(
                    TestPayload.self,
                    from: wire(json: "{\"\(sensitiveMarker)\":}")
                )
                throw TestFailure(description: "invalid JSON unexpectedly decoded")
            } catch let error as PluginPreviewFrameError {
                let description = error.localizedDescription
                try expect(!description.contains(sensitiveMarker), "error leaked frame content")
            }
        }

        print("SUMMARY passed=\(suite.passed) failed=\(suite.failed)")
        exit(suite.failed == 0 ? 0 : 1)
    }
}
