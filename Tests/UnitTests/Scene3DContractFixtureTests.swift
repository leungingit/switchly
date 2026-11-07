import Foundation
import XCTest
@testable import Switchly

/// T00 合同夹具：验证 scene3d 公开合同的正反样本，以及旧宿主/旧解码器的行为。
/// 这里不实现宿主渲染，只校验声明字段、GLB 预检结果与既有解码器边界。
final class Scene3DContractFixtureTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var fixtureRoot: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/Scene3D")
    }

    private func fixture(_ relativePath: String) throws -> [String: Any] {
        let url = Self.fixtureRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureFailure(message: "fixture is not a JSON object: \(relativePath)")
        }
        return root
    }

    private func repositoryAsset(_ relativePath: String) throws -> URL {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureFailure(message: "missing repository asset: \(relativePath)")
        }
        return url
    }

    private func renderOutputData(_ root: [String: Any]) throws -> Data {
        guard let output = root["renderOutput"] else {
            throw FixtureFailure(message: "renderOutput is missing")
        }
        return try JSONSerialization.data(withJSONObject: output)
    }

    // MARK: - 有效样本

    func testValidScene3DFixturesPassContractAndPreflight() throws {
        for relativePath in ["valid/ipod.json", "valid/barometer.json"] {
            let root = try fixture(relativePath)
            try Scene3DFixtureContract.validate(root)

            let assetPath = try XCTUnwrap(root["repositoryAsset"] as? String, relativePath)
            let data = try Data(contentsOf: repositoryAsset(assetPath), options: .mappedIfSafe)
            XCTAssertLessThanOrEqual(data.count, GLBPreflight.Budget.maxFileBytes, relativePath)
            let report = try GLBPreflight.inspect(data)

            let references = try Scene3DFixtureContract.referencedNodes(root)
            XCTAssertTrue(report.nodeNames.isSuperset(of: references), "\(relativePath) missing \(references.subtracting(report.nodeNames))")

            let uv = try Scene3DFixtureGLB.uvCoverage(data)
            for node in try Scene3DFixtureContract.surfaceNodes(root) {
                XCTAssertEqual(uv[node], true, "\(relativePath): surface node \(node) must be a single UV-complete mesh")
            }
            XCTAssertLessThanOrEqual(report.nodeCount, GLBPreflight.Budget.maxNodes, relativePath)
            XCTAssertLessThanOrEqual(report.meshCount, GLBPreflight.Budget.maxMeshes, relativePath)
            XCTAssertLessThanOrEqual(report.triangleCount, GLBPreflight.Budget.maxTriangles, relativePath)
        }
    }

    // MARK: - 旧布局与旧解码器

    func testLegacyLayoutStillDecodes() throws {
        let root = try fixture("legacy/layout.json")
        let output = try PluginRenderOutput.decode(json: renderOutputData(root))
        XCTAssertEqual(output.first?.slot, .center)
        XCTAssertEqual(output.first?.node.actionIDs, ["previous", "toggle", "next"])
    }

    func testDecoderRejectsUnknownNodeType() throws {
        let root = try fixture("invalid/unknown-node.json")
        XCTAssertThrowsError(try PluginRenderOutput.decode(json: renderOutputData(root))) { error in
            XCTAssertTrue(String(describing: error).contains("Unknown node type hologram"), "\(error)")
        }
    }

    // MARK: - 合同反例

    func testDuplicateActionIDIsRejectedByContract() throws {
        let root = try fixture("invalid/duplicate-action-id.json")
        assertContractError(root, contains: "duplicate action id toggle")
    }

    func testOverBudgetDeclarationIsRejectedByContract() throws {
        let root = try fixture("invalid/over-budget-declaration.json")
        assertContractError(root, contains: "surfaces exceeds 2")
    }

    func testMissingNamedNodeIsRuntimeFallbackNotDeclarationError() throws {
        let root = try fixture("invalid/missing-named-node.json")
        XCTAssertNoThrow(try Scene3DFixtureContract.validate(root))

        let assetPath = try XCTUnwrap(root["repositoryAsset"] as? String)
        let report = try GLBPreflight.inspect(Data(contentsOf: repositoryAsset(assetPath), options: .mappedIfSafe))
        let missing = try XCTUnwrap(root["missingNodes"] as? [String])
        for node in missing {
            XCTAssertFalse(report.nodeNames.contains(node), "fixture node \(node) unexpectedly exists")
        }
        XCTAssertEqual(root["expectedError"] as? String, "scene3d.nodeNotFound")
    }

    func testOverBudgetGLBIsRejectedByPreflight() throws {
        let data = try Data(contentsOf: Self.fixtureRoot.appendingPathComponent("invalid/over-budget.glb"))
        XCTAssertThrowsError(try GLBPreflight.inspect(data)) { error in
            XCTAssertTrue(String(describing: error).contains("too many nodes"), "unexpected error: \(error)")
        }
    }

    // MARK: - 旧宿主特性缺失

    func testLegacyHostWithoutUIFeaturesGets2DOutput() async throws {
        let directory = Self.fixtureRoot.appendingPathComponent("compat/legacy-host-missing-ui-features")
        let package = try PluginPackageValidator.load(directory: directory, origin: .user)
        let runtime = PluginRuntime(package: package, timeout: 0.5, uiFeatures: [:])
        let context = PluginRenderContext(bundleID: "com.example.app", pid: 42,
                                          appName: "Fixture", windowID: 7, titleSummary: "Fixture")
        let result = await runtime.renderJSON(context: context)
        runtime.unmount()

        switch result {
        case .success(let json):
            XCTAssertFalse(json.contains("\"scene3d\""), "legacy host must never receive scene3d: \(json)")
            XCTAssertTrue(json.contains("2D fallback"), "legacy host should receive the 2D tree: \(json)")
        case .failure(let error):
            XCTFail("legacy host fixture failed to render: \(error)")
        }
    }

    private func assertContractError(_ root: [String: Any], contains expected: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Scene3DFixtureContract.validate(root), file: file, line: line) { error in
            XCTAssertTrue(String(describing: error).contains(expected),
                          "expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

// MARK: - 声明合同校验（仅测试用，不是宿主实现）

private struct FixtureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum Scene3DFixtureContract {
    private static let allowedSurfaceContent: Set<String> = [
        "hstack", "vstack", "zstack", "spacer", "text",
        "progress", "image", "badge", "marquee"
    ]
    private static let forbiddenSurfaceContent: Set<String> = [
        "button", "toggle", "slider", "wheel", "screen", "surface", "scene", "scene3d"
    ]
    private static let minReadableWidth = 220
    private static let minReadableHeight = 380

    static func validate(_ root: [String: Any]) throws {
        guard let output = root["renderOutput"] as? [[String: Any]] else {
            throw FixtureFailure(message: "renderOutput must be an array")
        }
        var slots = Set<String>()
        for content in output {
            guard let slot = content["slot"] as? String,
                  let node = content["node"] as? [String: Any],
                  let type = node["type"] as? String else {
                throw FixtureFailure(message: "slot content is malformed")
            }
            guard slots.insert(slot).inserted else {
                throw FixtureFailure(message: "duplicate slot \(slot)")
            }
            if type == "scene3d" {
                try validateScene3D(node)
            } else if containsScene3D(node) {
                throw FixtureFailure(message: "scene3d only allowed as a slot root")
            }
        }
    }

    static func referencedNodes(_ root: [String: Any]) throws -> Set<String> {
        var result = Set<String>()
        for case let node as [String: Any] in outputNodes(root) where node["type"] as? String == "scene3d" {
            for surface in (node["surfaces"] as? [[String: Any]]) ?? [] {
                if let name = surface["node"] as? String { result.insert(name) }
            }
            for hit in (node["hits"] as? [[String: Any]]) ?? [] {
                if let name = hit["node"] as? String { result.insert(name) }
            }
        }
        return result
    }

    static func surfaceNodes(_ root: [String: Any]) throws -> [String] {
        var result: [String] = []
        for case let node as [String: Any] in outputNodes(root) where node["type"] as? String == "scene3d" {
            for surface in (node["surfaces"] as? [[String: Any]]) ?? [] {
                if let name = surface["node"] as? String { result.append(name) }
            }
        }
        return result
    }

    private static func outputNodes(_ root: [String: Any]) -> [Any] {
        ((root["renderOutput"] as? [[String: Any]]) ?? []).compactMap { $0["node"] }
    }

    private static func validateScene3D(_ node: [String: Any]) throws {
        guard let key = node["key"] as? String, !key.isEmpty, key.count <= 64 else {
            throw FixtureFailure(message: "scene3d key must be 1...64 characters")
        }
        guard let asset = node["asset"] as? String, isPackageRelativeGLB(asset) else {
            throw FixtureFailure(message: "scene3d asset must be a package-relative .glb")
        }
        if let fit = node["fit"] {
            guard fit as? String == "contain" else {
                throw FixtureFailure(message: "scene3d fit only supports contain")
            }
        }
        if let camera = node["camera"] as? [String: Any] {
            try validateNumber(camera["yaw"], range: -180...180, name: "camera yaw")
            try validateNumber(camera["pitch"], range: -89...89, name: "camera pitch")
        }
        if let rotate = node["rotate"] as? [String: Any] {
            for key in ["horizontal", "vertical"] where rotate[key] != nil {
                guard rotate[key] is Bool else { throw FixtureFailure(message: "rotate \(key) must be boolean") }
            }
            let pitchMin = try number(rotate["pitchMin"], name: "rotate pitchMin")
            let pitchMax = try number(rotate["pitchMax"], name: "rotate pitchMax")
            if pitchMin != nil || pitchMax != nil {
                guard let pitchMin, let pitchMax, pitchMin <= pitchMax,
                      (-89.0...89.0).contains(pitchMin), (-89.0...89.0).contains(pitchMax) else {
                    throw FixtureFailure(message: "rotate pitch range is invalid")
                }
            }
        }

        let surfaces = (node["surfaces"] as? [[String: Any]]) ?? []
        guard surfaces.count <= 2 else { throw FixtureFailure(message: "surfaces exceeds 2") }
        var surfaceNodeNames = Set<String>()
        for surface in surfaces {
            guard let name = surface["node"] as? String, !name.isEmpty else {
                throw FixtureFailure(message: "surface node is required")
            }
            guard surfaceNodeNames.insert(name).inserted else {
                throw FixtureFailure(message: "duplicate surface node \(name)")
            }
            guard let size = surface["size"] as? [NSNumber], size.count == 2 else {
                throw FixtureFailure(message: "surface size must be [width, height]")
            }
            for edge in size {
                let value = edge.doubleValue
                guard value.isFinite, value.rounded() == value, (1.0...1024.0).contains(value) else {
                    throw FixtureFailure(message: "surface size out of range")
                }
            }
            guard let content = surface["content"] as? [String: Any] else {
                throw FixtureFailure(message: "surface content is required")
            }
            var count = 0
            try validateSurfaceContent(content, depth: 1, count: &count)
        }

        let hits = (node["hits"] as? [[String: Any]]) ?? []
        guard hits.count <= 12 else { throw FixtureFailure(message: "hits exceeds 12") }
        var hitIDs = Set<String>()
        var hitNodeNames = Set<String>()
        for hit in hits {
            guard let name = hit["node"] as? String, !name.isEmpty,
                  let id = hit["id"] as? String, !id.isEmpty,
                  let label = hit["label"] as? String, !label.isEmpty else {
                throw FixtureFailure(message: "hit node/id/label are required")
            }
            guard hitIDs.insert(id).inserted else {
                throw FixtureFailure(message: "duplicate action id \(id)")
            }
            hitNodeNames.insert(name)
            if hit["value"] != nil { _ = hit["value"] as? NSNumber }
            if hit["enabled"] != nil, hit["enabled"] is Bool == false {
                throw FixtureFailure(message: "hit enabled must be boolean")
            }
        }
        guard surfaceNodeNames.isDisjoint(with: hitNodeNames) else {
            throw FixtureFailure(message: "surface and hit nodes must not overlap")
        }

        guard let fallback = node["fallback"] as? [String: Any] else {
            throw FixtureFailure(message: "scene3d fallback is required")
        }
        guard !containsScene3D(fallback) else {
            throw FixtureFailure(message: "scene3d fallback must not contain scene3d")
        }
        var fallbackIDs = Set<String>()
        for id in actionIDs(in: fallback) {
            guard fallbackIDs.insert(id).inserted else {
                throw FixtureFailure(message: "duplicate action id \(id)")
            }
        }
        // 唯一例外：hit 的业务 ID 可以在它自己的 fallback 子树中复用。
        // 其他 fallback ID 只要自身不重复，就不与 scene3d 的 hit 集合冲突。
        _ = fallbackIDs
    }

    private static func validateSurfaceContent(_ node: [String: Any], depth: Int, count: inout Int) throws {
        guard depth <= 8 else { throw FixtureFailure(message: "surface content is too deep") }
        guard let type = node["type"] as? String else {
            throw FixtureFailure(message: "surface content node type is required")
        }
        guard allowedSurfaceContent.contains(type) else {
            if forbiddenSurfaceContent.contains(type) {
                throw FixtureFailure(message: "surface content type \(type) is forbidden")
            }
            throw FixtureFailure(message: "surface content type \(type) is not allowed")
        }
        count += 1
        guard count <= 64 else { throw FixtureFailure(message: "surface content exceeds node budget") }
        for child in (node["children"] as? [[String: Any]]) ?? [] {
            try validateSurfaceContent(child, depth: depth + 1, count: &count)
        }
    }

    private static func actionIDs(in node: [String: Any]) -> [String] {
        guard let type = node["type"] as? String else { return [] }
        if ["button", "toggle", "slider"].contains(type), let id = node["id"] as? String {
            return [id]
        }
        if type == "scene", let hits = node["hits"] as? [[String: Any]] {
            return hits.compactMap { $0["id"] as? String }
        }
        return ((node["children"] as? [[String: Any]]) ?? []).flatMap(actionIDs(in:))
    }

    private static func containsScene3D(_ node: [String: Any]) -> Bool {
        if node["type"] as? String == "scene3d" { return true }
        return ((node["children"] as? [[String: Any]]) ?? []).contains(where: containsScene3D)
    }

    private static func isPackageRelativeGLB(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains(".."), path.lowercased().hasSuffix(".glb") else {
            return false
        }
        return !path.isEmpty
    }

    private static func validateNumber(_ value: Any?, range: ClosedRange<Double>, name: String) throws {
        guard value != nil else { return }
        let number = try number(value, name: name)
        guard let number, range.contains(number) else {
            throw FixtureFailure(message: "\(name) is out of range")
        }
    }

    private static func number(_ value: Any?, name: String, required: Bool = false) throws -> Double? {
        if value == nil {
            if required { throw FixtureFailure(message: "\(name) is required") }
            return nil
        }
        guard let number = value as? NSNumber, number.doubleValue.isFinite else {
            throw FixtureFailure(message: "\(name) must be a finite number")
        }
        return number.doubleValue
    }
}

// MARK: - GLB JSON 读取（只用于夹具 UV/节点断言）

private enum Scene3DFixtureGLB {
    private static let magic: UInt32 = 0x4654_6C67
    private static let jsonChunk: UInt32 = 0x4E4F_534A

    static func uvCoverage(_ data: Data) throws -> [String: Bool] {
        let root = try json(data)
        let nodes = (root["nodes"] as? [[String: Any]]) ?? []
        let meshes = (root["meshes"] as? [[String: Any]]) ?? []
        var result: [String: Bool] = [:]
        for node in nodes {
            guard let name = node["name"] as? String else { continue }
            guard let meshIndex = node["mesh"] as? Int, meshes.indices.contains(meshIndex) else {
                result[name] = false
                continue
            }
            let primitives = (meshes[meshIndex]["primitives"] as? [[String: Any]]) ?? []
            result[name] = !primitives.isEmpty && primitives.allSatisfy { primitive in
                ((primitive["attributes"] as? [String: Any])?["TEXCOORD_0"]) != nil
            }
        }
        return result
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard data.count >= 20, u32(data, 0) == magic, u32(data, 4) == 2 else {
            throw FixtureFailure(message: "fixture glb is not glTF 2.0 binary")
        }
        var offset = 12
        guard offset + 8 <= data.count else { throw FixtureFailure(message: "truncated glb chunk header") }
        let length = Int(u32(data, offset))
        guard u32(data, offset + 4) == jsonChunk, length >= 0, offset + 8 + length <= data.count else {
            throw FixtureFailure(message: "glb first chunk is not JSON")
        }
        let start = data.startIndex + offset + 8
        let jsonData = data.subdata(in: start..<(start + length))
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw FixtureFailure(message: "glb JSON chunk is malformed")
        }
        return root
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
