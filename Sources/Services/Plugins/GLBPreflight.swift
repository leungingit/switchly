import Foundation
import ImageIO

/// 在任何第三方 glTF 加载器之前对自包含 `.glb` 做硬边界检查（T01）。
/// 只读 header / chunk / JSON 与内嵌图片头，不解码顶点或像素；任何外部 URI、越界引用、
/// 未批准扩展或超预算都在这里确定性拒绝。JSON 类型错误、chunk 顺序/对齐不符与算术溢出
/// 也必须在这里失败，不能让 cgltf / GLTFKit2 先看到有歧义的输入。
enum GLBPreflight {
    enum Budget {
        static let maxFileBytes = 8 * 1024 * 1024
        static let maxMeshes = 128
        static let maxNodes = 256
        static let maxTriangles = 150_000
        static let maxTextureEdge = 2048
        static let maxDecodedTextureBytes = 32 * 1024 * 1024
        static let maxJSONDepth = 64
    }

    static let allowedExtensions: Set<String> = [
        "KHR_materials_clearcoat", "KHR_materials_emissive_strength", "KHR_materials_unlit"
    ]

    struct Failure: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct Report: Equatable {
        let nodeNames: Set<String>
        let meshCount: Int
        let nodeCount: Int
        let triangleCount: Int
        let decodedTextureBytes: Int
    }

    private static let magic: UInt32 = 0x4654_6C67   // "glTF"
    private static let chunkJSON: UInt32 = 0x4E4F_534A
    private static let chunkBIN: UInt32 = 0x004E_4942

    static func inspect(_ data: Data) throws -> Report {
        guard data.count <= Budget.maxFileBytes else { throw Failure(reason: "glb exceeds byte budget") }
        guard data.count >= 20 else { throw Failure(reason: "glb too short") }
        guard u32(data, 0) == magic, u32(data, 4) == 2 else { throw Failure(reason: "not a glTF 2.0 binary") }
        guard Int(u32(data, 8)) == data.count else { throw Failure(reason: "glb length mismatch") }

        // 单次扫描 chunk，JSON 与 BIN 的位置来自同一份解析结果，避免二次扫描错位。
        var offset = 12
        var chunkIndex = 0
        var json: Data?
        var binStart: Int?
        var binLength: Int?
        while offset < data.count {
            guard offset + 8 <= data.count else { throw Failure(reason: "truncated chunk header") }
            let length = Int(u32(data, offset))
            let type = u32(data, offset + 4)
            let start = offset + 8
            // cgltf 按原始 length 推进；未对齐的长度会让两个解析器看到不同边界。
            guard length % 4 == 0 else { throw Failure(reason: "chunk length is not 4-byte aligned") }
            guard length <= data.count - start else { throw Failure(reason: "chunk out of bounds") }
            if chunkIndex == 0 {
                guard type == chunkJSON else { throw Failure(reason: "first chunk must be JSON") }
                guard json == nil else { throw Failure(reason: "duplicate JSON chunk") }
                json = slice(data, start..<start + length)
            } else if chunkIndex == 1 {
                // cgltf 要求第二个 chunk 必须是 BIN；否则它会在加载阶段直接失败。
                guard type == chunkBIN else { throw Failure(reason: "second chunk must be BIN") }
                binStart = start
                binLength = length
            } else if type == chunkJSON {
                throw Failure(reason: "duplicate JSON chunk")
            } else if type == chunkBIN {
                throw Failure(reason: "duplicate BIN chunk")
            }
            // 第三个及之后的未知 chunk 被 cgltf 忽略，这里只校验边界后跳过。
            offset = start + length
            chunkIndex += 1
        }
        guard let json else { throw Failure(reason: "missing JSON chunk") }
        guard offset == data.count else { throw Failure(reason: "glb length mismatch") }
        guard hasSafeJSONNesting(json) else { throw Failure(reason: "glTF JSON is nested too deeply") }
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw Failure(reason: "malformed glTF JSON")
        }
        return try validate(root: root, binStart: binStart, binLength: binLength, glb: data)
    }

    // MARK: - JSON validation

    private static func validate(root: [String: Any], binStart: Int?, binLength: Int?, glb: Data) throws -> Report {
        for key in ["extensionsUsed", "extensionsRequired"] {
            for name in try stringArray(root, key) where !allowedExtensions.contains(name) {
                throw Failure(reason: "extension not allowed: \(name)")
            }
        }
        // 扩展白名单不能只依赖 extensionsUsed：任何位置的 extension 对象都必须同名可查。
        try validateExtensionObjects(root)

        let buffers = try objects(root, "buffers")
        var bufferLength: Int?
        if buffers.isEmpty {
            guard binLength == nil else { throw Failure(reason: "BIN chunk requires an embedded buffer declaration") }
        } else {
            guard buffers.count == 1 else { throw Failure(reason: "multiple buffers are not allowed") }
            let buffer = buffers[0]
            guard buffer["uri"] == nil else { throw Failure(reason: "external buffer uri is not allowed") }
            guard let binLength else { throw Failure(reason: "buffer is not the embedded GLB chunk") }
            let declared = try requiredInteger(buffer["byteLength"], field: "buffers[0].byteLength")
            guard declared >= 0, declared <= binLength else {
                throw Failure(reason: "buffer is not the embedded GLB chunk")
            }
            bufferLength = declared
        }
        let views = try objects(root, "bufferViews")
        for view in views { _ = try viewRange(view, bufferLength: bufferLength) }

        let nodes = try objects(root, "nodes")
        let meshes = try objects(root, "meshes")
        guard nodes.count <= Budget.maxNodes else { throw Failure(reason: "too many nodes") }
        guard meshes.count <= Budget.maxMeshes else { throw Failure(reason: "too many meshes") }
        var names = Set<String>()
        for (index, node) in nodes.enumerated() {
            guard let rawName = node["name"] else { continue }
            guard let name = rawName as? String else {
                throw Failure(reason: "nodes[\(index)].name must be a string")
            }
            guard !name.isEmpty, names.insert(name).inserted else { throw Failure(reason: "empty or duplicate node name") }
        }

        let accessors = try objects(root, "accessors")
        var accessorCounts: [Int] = []
        accessorCounts.reserveCapacity(accessors.count)
        for (index, accessor) in accessors.enumerated() {
            let count = try requiredInteger(accessor["count"], field: "accessors[\(index)].count")
            guard count >= 0 else { throw Failure(reason: "accessor count must be non-negative") }
            if let rawView = accessor["bufferView"] {
                let viewIndex = try requiredInteger(rawView, field: "accessors[\(index)].bufferView")
                guard views.indices.contains(viewIndex) else { throw Failure(reason: "accessor bufferView out of bounds") }
            }
            accessorCounts.append(count)
        }

        var triangles = 0
        for (meshIndex, mesh) in meshes.enumerated() {
            guard let rawPrimitives = mesh["primitives"] else { continue }
            guard let primitives = rawPrimitives as? [Any] else {
                throw Failure(reason: "meshes[\(meshIndex)].primitives must be an array")
            }
            for (primitiveIndex, rawPrimitive) in primitives.enumerated() {
                let prefix = "meshes[\(meshIndex)].primitives[\(primitiveIndex)]"
                guard let primitive = rawPrimitive as? [String: Any] else {
                    throw Failure(reason: "\(prefix) must be an object")
                }
                let mode = try integer(primitive["mode"], field: "\(prefix).mode") ?? 4
                guard mode == 4 else { throw Failure(reason: "only triangle primitives are allowed") }
                guard let rawAttributes = primitive["attributes"] else {
                    throw Failure(reason: "\(prefix).attributes is required")
                }
                guard let attributes = rawAttributes as? [String: Any] else {
                    throw Failure(reason: "\(prefix).attributes must be an object")
                }
                var positionIndex: Int?
                for (semantic, rawAccessor) in attributes {
                    let accessorIndex = try requiredInteger(rawAccessor, field: "\(prefix).attributes.\(semantic)")
                    guard accessors.indices.contains(accessorIndex) else {
                        throw Failure(reason: "invalid primitive accessor")
                    }
                    if semantic == "POSITION" { positionIndex = accessorIndex }
                }
                let indices = try integer(primitive["indices"], field: "\(prefix).indices")
                let source: Int
                if let indices {
                    source = indices
                } else if let positionIndex {
                    source = positionIndex
                } else {
                    throw Failure(reason: "invalid primitive accessor")
                }
                guard accessors.indices.contains(source) else { throw Failure(reason: "invalid primitive accessor") }
                let (total, overflow) = triangles.addingReportingOverflow(accessorCounts[source] / 3)
                guard !overflow, total <= Budget.maxTriangles else { throw Failure(reason: "too many triangles") }
                triangles = total
            }
        }

        var textureBytes = 0
        let images = try objects(root, "images")
        for (imageIndex, image) in images.enumerated() {
            guard image["uri"] == nil else { throw Failure(reason: "external image uri is not allowed") }
            guard let rawView = image["bufferView"] else {
                throw Failure(reason: "image must reference an embedded bufferView")
            }
            let viewIndex = try requiredInteger(rawView, field: "images[\(imageIndex)].bufferView")
            guard views.indices.contains(viewIndex) else {
                throw Failure(reason: "image must reference an embedded bufferView")
            }
            let range = try viewRange(views[viewIndex], bufferLength: bufferLength)
            guard let binStart else { throw Failure(reason: "missing BIN chunk") }
            let bytes = slice(glb, binStart + range.lowerBound..<binStart + range.upperBound)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let widthNumber = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let heightNumber = props[kCGImagePropertyPixelHeight] as? NSNumber,
                  let width = Int(exactly: widthNumber.doubleValue),
                  let height = Int(exactly: heightNumber.doubleValue),
                  width > 0, height > 0 else {
                throw Failure(reason: "unreadable embedded image")
            }
            guard width <= Budget.maxTextureEdge, height <= Budget.maxTextureEdge else {
                throw Failure(reason: "texture edge exceeds budget")
            }
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            guard !pixelOverflow else { throw Failure(reason: "decoded texture budget exceeded") }
            let (byteCount, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            guard !byteOverflow else { throw Failure(reason: "decoded texture budget exceeded") }
            let (total, totalOverflow) = textureBytes.addingReportingOverflow(byteCount)
            guard !totalOverflow, total <= Budget.maxDecodedTextureBytes else {
                throw Failure(reason: "decoded texture budget exceeded")
            }
            textureBytes = total
        }
        return Report(nodeNames: names, meshCount: meshes.count, nodeCount: nodes.count,
                      triangleCount: triangles, decodedTextureBytes: textureBytes)
    }

    // MARK: - Helpers

    private static func objects(_ root: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let value = root[key] else { return [] }
        guard let array = value as? [Any] else { throw Failure(reason: "\(key) must be an array") }
        var result: [[String: Any]] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let object = element as? [String: Any] else {
                throw Failure(reason: "\(key) must contain objects")
            }
            result.append(object)
        }
        return result
    }

    private static func stringArray(_ root: [String: Any], _ key: String) throws -> [String] {
        guard let value = root[key] else { return [] }
        guard let array = value as? [Any] else { throw Failure(reason: "\(key) must be an array") }
        var result: [String] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let string = element as? String else {
                throw Failure(reason: "\(key) must contain strings")
            }
            result.append(string)
        }
        return result
    }

    /// JSONSerialization 会把 true / 1.0 / 2^63 都桥接成可被 `as? Int` 接受的值，
    /// 因此先排除布尔，再用 `Int(exactly:)` 拒绝非整数与不可表示的大数。
    private static func integer(_ value: Any?, field: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue) else {
            throw Failure(reason: "\(field) must be a JSON integer")
        }
        return integer
    }

    private static func requiredInteger(_ value: Any?, field: String) throws -> Int {
        guard let value else { throw Failure(reason: "\(field) is required") }
        guard let integer = try integer(value, field: field) else {
            throw Failure(reason: "\(field) must be a JSON integer")
        }
        return integer
    }

    private static func viewRange(_ view: [String: Any], bufferLength: Int?) throws -> Range<Int> {
        guard let bufferLength else { throw Failure(reason: "bufferView requires an embedded buffer") }
        let bufferIndex = try requiredInteger(view["buffer"], field: "bufferView.buffer")
        guard bufferIndex == 0 else { throw Failure(reason: "invalid bufferView") }
        let length = try requiredInteger(view["byteLength"], field: "bufferView.byteLength")
        let offset = try integer(view["byteOffset"], field: "bufferView.byteOffset") ?? 0
        guard length >= 0, offset >= 0, offset <= bufferLength, length <= bufferLength - offset else {
            throw Failure(reason: "bufferView out of bounds")
        }
        return offset..<offset + length
    }

    /// cgltf 用声明的 `buffer.byteLength` 校验 bufferView，而不是 BIN chunk 长度；
    /// 预检必须与加载器同一口径，否则可构造“chunk 内、声明外”的越界读取。
    private static func validateExtensionObjects(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            if let extensions = dictionary["extensions"] {
                guard let extensionObject = extensions as? [String: Any] else {
                    throw Failure(reason: "extensions must be an object")
                }
                for (name, payload) in extensionObject {
                    guard allowedExtensions.contains(name) else {
                        throw Failure(reason: "extension not allowed: \(name)")
                    }
                    try validateExtensionObjects(payload)
                }
            }
            // extras 是任意 JSON，不允许在其中借道隐藏扩展声明。
            for (key, child) in dictionary where key != "extensions" && key != "extras" {
                try validateExtensionObjects(child)
            }
        } else if let array = value as? [Any] {
            for element in array { try validateExtensionObjects(element) }
        }
    }

    /// 在 JSONSerialization 之前按字节扫描嵌套深度，避免解析器在超深输入上消耗栈。
    private static func hasSafeJSONNesting(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > Budget.maxJSONDepth { return false }
            case 0x7D, 0x5D:
                depth -= 1
            default:
                break
            }
        }
        return true
    }

    private static func slice(_ data: Data, _ range: Range<Int>) -> Data {
        let start = data.startIndex + range.lowerBound
        let end = data.startIndex + range.upperBound
        return data.subdata(in: start..<end)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
