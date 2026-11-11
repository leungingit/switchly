import XCTest
@testable import Switchly

final class GLBPreflightTests: XCTestCase {
    /// 合成 GLB：JSON chunk + 可选 BIN chunk，均 4 字节对齐。
    private func glb(_ json: [String: Any], bin: Data? = Data(count: 64)) throws -> Data {
        var text = try JSONSerialization.data(withJSONObject: json)
        while text.count % 4 != 0 { text.append(0x20) }
        var body = chunk(0x4E4F_534A, text)
        if var bin {
            while bin.count % 4 != 0 { bin.append(0) }
            body.append(chunk(0x004E_4942, bin))
        }
        var out = Data()
        out.append(le(0x4654_6C67)); out.append(le(2)); out.append(le(UInt32(12 + body.count)))
        out.append(body)
        return out
    }

    private func chunk(_ type: UInt32, _ payload: Data) -> Data {
        var d = Data(); d.append(le(UInt32(payload.count))); d.append(le(type)); d.append(payload); return d
    }

    private func le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    /// 原始 chunk 容器：不做对齐或补齐，用于构造畸形长度与顺序。
    private func container(_ chunks: [(type: UInt32, payload: Data)]) -> Data {
        var body = Data()
        for (type, payload) in chunks {
            body.append(le(UInt32(payload.count)))
            body.append(le(type))
            body.append(payload)
        }
        var out = Data()
        out.append(le(0x4654_6C67)); out.append(le(2)); out.append(le(UInt32(12 + body.count)))
        out.append(body)
        return out
    }

    private func paddedJSON(_ json: [String: Any]) throws -> Data {
        var text = try JSONSerialization.data(withJSONObject: json)
        while text.count % 4 != 0 { text.append(0x20) }
        return text
    }

    private func jsonData(_ text: String) -> Data {
        var data = Data(text.utf8)
        while data.count % 4 != 0 { data.append(0x20) }
        return data
    }

    private let base: [String: Any] = [
        "asset": ["version": "2.0"],
        "buffers": [["byteLength": 64]],
        "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 32]],
        "nodes": [["name": "mesh_screen"], ["name": "mesh_wheel_play"]]
    ]

    private func merged(_ extra: [String: Any]) -> [String: Any] {
        base.merging(extra) { _, new in new }
    }

    private func assertRejected(_ data: Data, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GLBPreflight.inspect(data), file: file, line: line) { error in
            XCTAssertTrue((error as? GLBPreflight.Failure)?.reason.contains(text) == true,
                          "unexpected: \(error)", file: file, line: line)
        }
    }

    func testValidMinimalGLBReportsNodeNames() throws {
        let report = try GLBPreflight.inspect(try glb(base))
        XCTAssertEqual(report.nodeNames, ["mesh_screen", "mesh_wheel_play"])
        XCTAssertEqual(report.nodeCount, 2)
    }

    func testExternalAndNetworkURIsAreRejectedBeforeAnyLoader() throws {
        for uri in ["../../sentinel.png", "/etc/passwd", "https://example.com/a.bin"] {
            assertRejected(try glb(merged(["buffers": [["byteLength": 64, "uri": uri]]])), contains: "external buffer")
            assertRejected(try glb(merged(["images": [["uri": uri]]])), contains: "external image")
        }
    }

    func testOutOfBoundsBufferViewIsRejected() throws {
        let views: [[String: Any]] = [["buffer": 0, "byteOffset": 48, "byteLength": 32]]
        assertRejected(try glb(merged(["bufferViews": views])), contains: "out of bounds")
    }

    func testDisallowedExtensionIsRejected() throws {
        assertRejected(try glb(merged(["extensionsUsed": ["KHR_draco_mesh_compression"]])), contains: "extension not allowed")
        XCTAssertNoThrow(try GLBPreflight.inspect(try glb(merged(["extensionsUsed": ["KHR_materials_clearcoat"]]))))
    }

    func testDuplicateOrEmptyNodeNamesAreRejected() throws {
        assertRejected(try glb(merged(["nodes": [["name": "a"], ["name": "a"]]])), contains: "duplicate")
        assertRejected(try glb(merged(["nodes": [["name": ""]]])), contains: "duplicate")
    }

    func testTooManyNodesAreRejected() throws {
        let nodes = (0...GLBPreflight.Budget.maxNodes).map { ["name": "n\($0)"] }
        assertRejected(try glb(merged(["nodes": nodes])), contains: "too many nodes")
    }

    func testTriangleBudgetIsEnforced() throws {
        let count = (GLBPreflight.Budget.maxTriangles + 1) * 3
        let json = merged([
            "accessors": [["count": count]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]]
        ])
        assertRejected(try glb(json), contains: "too many triangles")
    }

    func testNonTrianglePrimitiveIsRejected() throws {
        let json = merged([
            "accessors": [["count": 3]],
            "meshes": [["primitives": [["mode": 1, "attributes": ["POSITION": 0]]]]]
        ])
        assertRejected(try glb(json), contains: "triangle")
    }

    func testImageMustBeEmbeddedAndReadable() throws {
        assertRejected(try glb(merged(["images": [["mimeType": "image/png"]]])), contains: "embedded bufferView")
        assertRejected(try glb(merged(["images": [["bufferView": 0, "mimeType": "image/png"]]])), contains: "unreadable")
    }

    func testCorruptContainersAreRejected() throws {
        let good = try glb(base)
        assertRejected(Data(), contains: "too short")
        assertRejected(Data(good.prefix(good.count - 4)), contains: "length mismatch")
        var badMagic = good; badMagic[0] = 0
        assertRejected(badMagic, contains: "not a glTF")
        var badJSON = Data()
        let payload = Data("{not json".utf8 + [0x20, 0x20, 0x20])
        let body = chunk(0x4E4F_534A, payload)
        badJSON.append(le(0x4654_6C67)); badJSON.append(le(2)); badJSON.append(le(UInt32(12 + body.count))); badJSON.append(body)
        assertRejected(badJSON, contains: "malformed")
    }

    func testOversizedFileIsRejected() {
        assertRejected(Data(count: GLBPreflight.Budget.maxFileBytes + 1), contains: "byte budget")
    }

    func testPackageValidatorRejectsPackageWithBadGLB() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glb-pkg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = """
        {"id":"com.example.glb","name":{"en":"G"},"version":"1.0.0","apiVersion":1,
         "matches":["com.example.target"],"permissions":[],"entry":"main.js"}
        """
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("globalThis.__switchlyPlugin={render:()=>[]};".utf8).write(to: dir.appendingPathComponent("main.js"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("assets/bad.glb"))
        XCTAssertThrowsError(try PluginPackageValidator.load(directory: dir, origin: .user)) { error in
            XCTAssertTrue("\(error)".contains("bad.glb") || (error as? PluginPackageValidator.Failure)?.reason.contains("bad.glb") == true)
        }
        try glb(base).write(to: dir.appendingPathComponent("assets/bad.glb"))
        XCTAssertNoThrow(try PluginPackageValidator.load(directory: dir, origin: .user))
    }

    func testRealProbeAssetsPassPreflight() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugins/assets/3d-loading-probe-2026-11-06")
        for name in ["barometer.glb", "ipod-source-geometry.glb"] {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("probe asset missing: \(name)") }
            let report = try GLBPreflight.inspect(Data(contentsOf: url))
            XCTAssertGreaterThan(report.nodeCount, 0, name)
        }
    }

    // MARK: - 畸形 JSON 类型

    func testMalformedJSONContainerTypesAreRejected() throws {
        assertRejected(try glb(merged(["nodes": "n"])), contains: "nodes must be an array")
        assertRejected(try glb(merged(["nodes": [1]])), contains: "nodes must contain objects")
        assertRejected(try glb(merged(["meshes": [1]])), contains: "meshes must contain objects")
        assertRejected(try glb(merged(["accessors": "x"])), contains: "accessors must be an array")
        assertRejected(try glb(merged(["bufferViews": "x"])), contains: "bufferViews must be an array")
        assertRejected(try glb(merged(["buffers": "x"])), contains: "buffers must be an array")
        assertRejected(try glb(merged(["images": [1]])), contains: "images must contain objects")
        assertRejected(try glb(merged(["extensionsUsed": [1]])), contains: "extensionsUsed must contain strings")
    }

    func testNumericJSONTypesAreStrict() throws {
        assertRejected(try glb(merged(["buffers": [["byteLength": "64"]]])), contains: "JSON integer")
        assertRejected(try glb(merged(["buffers": [["byteLength": true]]])), contains: "JSON integer")
        assertRejected(try glb(merged(["buffers": [["byteLength": 64.5]]])), contains: "JSON integer")
        assertRejected(try glb(merged(["bufferViews": [["buffer": true, "byteLength": 32]]])), contains: "JSON integer")
        assertRejected(try glb(merged(["bufferViews": [["buffer": 0, "byteLength": 32, "byteOffset": "0"]]])),
                       contains: "JSON integer")
        assertRejected(try glb(merged(["accessors": [["count": 3, "bufferView": true]]])), contains: "JSON integer")
        assertRejected(try glb(merged(["nodes": [["name": 7]]])), contains: "name must be a string")
        assertRejected(try glb(merged(["images": [["bufferView": "0"]]])), contains: "JSON integer")
    }

    // MARK: - accessor 算术与引用

    func testAccessorCountBoundariesAreRejected() throws {
        let primitiveMesh: [String: Any] = ["primitives": [["attributes": ["POSITION": 0]]]]
        let massive = 4_611_686_018_427_387_904   // 2^62，可被 Double 精确表示
        assertRejected(try glb(merged(["accessors": [["count": massive]], "meshes": [primitiveMesh]])),
                       contains: "too many triangles")
        assertRejected(try glb(merged(["accessors": [["count": 3.5]], "meshes": [primitiveMesh]])),
                       contains: "JSON integer")
        assertRejected(try glb(merged(["accessors": [["count": true]], "meshes": [primitiveMesh]])),
                       contains: "JSON integer")
        assertRejected(try glb(merged(["accessors": [["count": -1]], "meshes": [primitiveMesh]])),
                       contains: "non-negative")
        assertRejected(try glb(merged(["accessors": [["bufferView": 0]], "meshes": [primitiveMesh]])),
                       contains: "count is required")
        // Int.max 的 JSON 数字经 Double 会变成 2^63，必须按不可表示的大数拒绝。
        let intMax = "{\"asset\":{\"version\":\"2.0\"},\"accessors\":[{\"count\":9223372036854775807}]}"
        assertRejected(container([(0x4E4F_534A, jsonData(intMax))]), contains: "JSON integer")
    }

    func testPrimitiveTypesAndReferencesAreStrict() throws {
        let accessors: [[String: Any]] = [["count": 3]]
        assertRejected(try glb(merged(["accessors": accessors,
                                       "meshes": [["primitives": [["mode": "4", "attributes": ["POSITION": 0]]]]]])),
                       contains: "mode must be a JSON integer")
        assertRejected(try glb(merged(["accessors": accessors,
                                       "meshes": [["primitives": [["mode": true, "attributes": ["POSITION": 0]]]]]])),
                       contains: "mode must be a JSON integer")
        assertRejected(try glb(merged(["accessors": accessors,
                                       "meshes": [["primitives": [["attributes": ["POSITION": "0"]]]]]])),
                       contains: "POSITION must be a JSON integer")
        assertRejected(try glb(merged(["accessors": accessors,
                                       "meshes": [["primitives": [["attributes": ["POSITION": 9]]]]]])),
                       contains: "invalid primitive accessor")
        // indices 类型错误不能静默回退到 POSITION。
        assertRejected(try glb(merged(["accessors": accessors,
                                       "meshes": [["primitives": [["indices": "0", "attributes": ["POSITION": 0]]]]]])),
                       contains: "indices must be a JSON integer")
        assertRejected(try glb(merged(["accessors": accessors,
                                       "meshes": [["primitives": [[ "attributes": ["NORMAL": 0]]]]]])),
                       contains: "invalid primitive accessor")
        assertRejected(try glb(merged(["accessors": accessors, "meshes": [["primitives": [1]]]])),
                       contains: "must be an object")
        assertRejected(try glb(merged(["accessors": accessors, "meshes": [["primitives": "x"]]])),
                       contains: "primitives must be an array")
    }

    // MARK: - chunk 与 buffer 声明一致性

    func testChunkOrderAlignmentAndDuplicatesAreStrict() throws {
        let json = try paddedJSON(base)
        let unalignedJSON = Data("{\"asset\":{\"version\":\"2.0\"}}".utf8)
        assertRejected(container([(0x4E4F_534A, unalignedJSON)]), contains: "4-byte aligned")
        assertRejected(container([(0x4E4F_534A, json), (0xDEAD_BEEF, Data(count: 4))]),
                       contains: "second chunk must be BIN")
        assertRejected(container([(0x4E4F_534A, json), (0x004E_4942, Data(count: 64)),
                                  (0x4E4F_534A, Data(count: 4))]), contains: "duplicate JSON chunk")
        assertRejected(container([(0x4E4F_534A, json), (0x004E_4942, Data(count: 64)),
                                  (0x004E_4942, Data(count: 4))]), contains: "duplicate BIN chunk")
        assertRejected(container([(0x4E4F_534A, json), (0x004E_4942, Data(count: 3))]),
                       contains: "4-byte aligned")
        // cgltf 忽略第三个未知 chunk，预检允许同样的后缀但只做边界校验。
        XCTAssertNoThrow(try GLBPreflight.inspect(container([
            (0x4E4F_534A, json), (0x004E_4942, Data(count: 64)), (0xDEAD_BEEF, Data(count: 4))
        ])))
    }

    func testChunkAndBufferDeclarationsMustAgree() throws {
        assertRejected(try glb(["asset": ["version": "2.0"]]), contains: "BIN chunk requires")
        assertRejected(try glb(merged(["buffers": [["byteLength": 96]]])), contains: "embedded GLB chunk")
        assertRejected(try glb(merged(["buffers": [["byteLength": 16]],
                                       "bufferViews": [["buffer": 0, "byteLength": 32]]])),
                       contains: "out of bounds")
        assertRejected(try glb(merged(["buffers": [["byteLength": 64], ["byteLength": 16]]])),
                       contains: "multiple buffers")
        XCTAssertNoThrow(try GLBPreflight.inspect(try glb(["asset": ["version": "2.0"]], bin: nil)))
    }

    // MARK: - 扩展与 JSON 深度

    func testExtensionObjectsCannotBypassWhitelist() throws {
        let emptyExtension: [String: Any] = [:]
        let primitive: [String: Any] = [
            "attributes": ["POSITION": 0],
            "extensions": ["KHR_draco_mesh_compression": emptyExtension]
        ]
        assertRejected(try glb(merged(["accessors": [["count": 3]],
                                       "meshes": [["primitives": [primitive]]]])),
                       contains: "extension not allowed: KHR_draco_mesh_compression")
        let material: [String: Any] = ["extensions": ["KHR_materials_unlit": emptyExtension]]
        XCTAssertNoThrow(try GLBPreflight.inspect(try glb(merged([
            "extensionsUsed": ["KHR_materials_unlit"],
            "materials": [material]
        ]))))
        // extras 是任意 JSON，不应被当成扩展表；其中同名键必须豁免。
        let node: [String: Any] = ["name": "mesh_screen",
                                   "extras": ["extensions": ["vendor": emptyExtension]]]
        XCTAssertNoThrow(try GLBPreflight.inspect(try glb(merged(["nodes": [node]]))))
        assertRejected(try glb(merged(["extensions": "x"])), contains: "extensions must be an object")
    }

    func testJSONNestingIsBoundedBeforeParsing() throws {
        let depth = GLBPreflight.Budget.maxJSONDepth + 4
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let deep = "{\"asset\":{\"version\":\"2.0\"},\"extras\":\(nested)}"
        assertRejected(container([(0x4E4F_534A, jsonData(deep))]), contains: "nested too deeply")
        let shallow = "{\"asset\":{\"version\":\"2.0\"},\"extras\":[[[]]]}"
        XCTAssertNoThrow(try GLBPreflight.inspect(container([(0x4E4F_534A, jsonData(shallow))])))
    }
}
