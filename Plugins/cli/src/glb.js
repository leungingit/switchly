import { crc32 } from "./png.js";

/**
 * 零依赖 GLB 硬边界预检；图片格式等检查可能比宿主 GLBPreflight 更严格。
 * 只读取容器、JSON 与内嵌图片头，不加载 glTF、不解码像素；宿主仍在交给
 * GLTFKit2 前执行最终防线。
 */
export const glbLimits = Object.freeze({
  maxFileBytes: 8 * 1024 * 1024,
  maxMeshes: 128,
  maxNodes: 256,
  maxTriangles: 150000,
  maxTextureEdge: 2048,
  maxDecodedTextureBytes: 32 * 1024 * 1024,
  maxJSONDepth: 64,
});

export const glbAllowedExtensions = Object.freeze([
  "KHR_materials_clearcoat",
  "KHR_materials_emissive_strength",
  "KHR_materials_unlit",
]);

const allowedExtensions = new Set(glbAllowedExtensions);
const MAGIC = 0x46546c67; // "glTF"
const CHUNK_JSON = 0x4e4f534a; // "JSON"
const CHUNK_BIN = 0x004e4942; // "BIN\0"
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const JPEG_SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
  0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

export class GLBError extends Error {
  constructor(code, reason = code) {
    super(reason);
    this.name = "GLBError";
    this.code = code;
    this.reason = reason;
  }
}

function fail(code, reason = code) {
  throw new GLBError(code, reason);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function objectArray(root, key) {
  const value = root[key];
  if (value === undefined) return [];
  if (!Array.isArray(value)) fail("malformed-glTF-json", `${key} must be an array`);
  if (!value.every(isObject)) fail("malformed-glTF-json", `${key} must contain objects`);
  return value;
}

function stringArray(root, key) {
  const value = root[key];
  if (value === undefined) return [];
  if (!Array.isArray(value)) fail("malformed-glTF-json", `${key} must be an array`);
  if (!value.every((item) => typeof item === "string")) {
    fail("malformed-glTF-json", `${key} must contain strings`);
  }
  return value;
}

function isInteger(value) {
  // 宿主用 Int(exactly:) 校验 JSON 数字；2^63 在 Double 中仍是整数，
  // 但已超出 Int 范围，JSON 里的 Int.max 也会被解析成 2^63。
  return typeof value === "number"
    && Number.isInteger(value)
    && value >= -(2 ** 63)
    && value < 2 ** 63;
}

function requiredInteger(value, field, code) {
  if (value === undefined) fail(code, `${field} is required`);
  if (!isInteger(value)) fail(code, `${field} must be a JSON integer`);
  return value;
}

function optionalInteger(value, field, code) {
  if (value === undefined) return undefined;
  return requiredInteger(value, field, code);
}

/** 与宿主一样在 JSON 解析前按字节扫描，避免超深输入先耗尽解析器栈。 */
function hasSafeJSONNesting(data) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (const byte of data) {
    if (inString) {
      if (escaped) escaped = false;
      else if (byte === 0x5c) escaped = true;
      else if (byte === 0x22) inString = false;
      continue;
    }
    if (byte === 0x22) {
      inString = true;
    } else if (byte === 0x7b || byte === 0x5b) {
      depth += 1;
      if (depth > glbLimits.maxJSONDepth) return false;
    } else if (byte === 0x7d || byte === 0x5d) {
      depth -= 1;
    }
  }
  return true;
}

/** 扩展白名单不能只依赖 extensionsUsed；extras 是任意 JSON，予以豁免。 */
function validateExtensionObjects(value) {
  if (Array.isArray(value)) {
    for (const element of value) validateExtensionObjects(element);
    return;
  }
  if (!isObject(value)) return;
  if (Object.prototype.hasOwnProperty.call(value, "extensions")) {
    const extensions = value.extensions;
    if (!isObject(extensions)) fail("malformed-glTF-json", "extensions must be an object");
    for (const [name, payload] of Object.entries(extensions)) {
      if (!allowedExtensions.has(name)) {
        fail("extension-not-allowed", `extension not allowed: ${name}`);
      }
      validateExtensionObjects(payload);
    }
  }
  for (const [key, child] of Object.entries(value)) {
    if (key === "extensions" || key === "extras") continue;
    validateExtensionObjects(child);
  }
}

function u32(data, offset) {
  return data.readUInt32LE(offset);
}

function viewRange(view, bufferLength) {
  if (bufferLength === null) fail("buffer-view-without-buffer", "bufferView requires an embedded buffer");
  const bufferIndex = requiredInteger(view.buffer, "bufferView.buffer", "invalid-buffer-view");
  if (bufferIndex !== 0) fail("invalid-buffer-view", "invalid bufferView");
  const length = requiredInteger(view.byteLength, "bufferView.byteLength", "invalid-buffer-view");
  const offset = optionalInteger(view.byteOffset, "bufferView.byteOffset", "invalid-buffer-view") ?? 0;
  if (length < 0 || offset < 0 || offset > bufferLength || length > bufferLength - offset) {
    fail("buffer-view-out-of-bounds", "bufferView out of bounds");
  }
  return { start: offset, end: offset + length };
}

function embeddedImageSize(bytes) {
  return pngSize(bytes) ?? jpegSize(bytes);
}

function pngSize(bytes) {
  if (bytes.length < 8 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return null;
  let offset = 8;
  let header = null;
  let sawIDAT = false;
  let sawIEND = false;
  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset);
    if (length > bytes.length - offset - 12) return null;
    const type = bytes.toString("latin1", offset + 4, offset + 8);
    const end = offset + 12 + length;
    const expectedCRC = bytes.readUInt32BE(offset + 8 + length);
    if (crc32(bytes.subarray(offset + 4, offset + 8 + length)) !== expectedCRC) return null;
    if (header === null) {
      if (type !== "IHDR" || length !== 13) return null;
      header = {
        width: bytes.readUInt32BE(offset + 8),
        height: bytes.readUInt32BE(offset + 12),
      };
    } else if (type === "IDAT" && length > 0) {
      sawIDAT = true;
    } else if (type === "IEND") {
      sawIEND = true;
      break;
    }
    offset = end;
  }
  if (!header || !sawIDAT || !sawIEND || header.width === 0 || header.height === 0) return null;
  return header;
}

function jpegSize(bytes) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset] !== 0xff) return null;
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) return null;
    const marker = bytes[offset];
    offset += 1;
    if (marker === 0x00) return null;
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (marker === 0xd9) return null;
    if (offset + 2 > bytes.length) return null;
    const segmentLength = bytes.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > bytes.length) return null;
    if (JPEG_SOF_MARKERS.has(marker)) {
      if (segmentLength < 7) return null;
      const height = bytes.readUInt16BE(offset + 3);
      const width = bytes.readUInt16BE(offset + 5);
      if (width === 0 || height === 0) return null;
      return { width, height };
    }
    if (marker === 0xda) return null;
    offset += segmentLength;
  }
  return null;
}

function nodeUV(meshes, node) {
  if (!isInteger(node.mesh) || node.mesh < 0 || node.mesh >= meshes.length) return false;
  const primitives = meshes[node.mesh].primitives;
  if (!Array.isArray(primitives) || primitives.length === 0 || !primitives.every(isObject)) return false;
  return primitives.every((primitive) => {
    const attributes = primitive.attributes;
    return isObject(attributes)
      && Object.prototype.hasOwnProperty.call(attributes, "TEXCOORD_0");
  });
}

function validate(root, glb, binStart, binLength) {
  for (const key of ["extensionsUsed", "extensionsRequired"]) {
    for (const name of stringArray(root, key)) {
      if (!allowedExtensions.has(name)) {
        fail("extension-not-allowed", `extension not allowed: ${name}`);
      }
    }
  }
  validateExtensionObjects(root);

  // 声明的 buffer 必须就是唯一的内嵌 BIN chunk；未声明 buffer 时不得附带 BIN。
  const buffers = objectArray(root, "buffers");
  let bufferLength = null;
  if (buffers.length === 0) {
    if (binLength !== null) {
      fail("unexpected-bin-chunk", "BIN chunk requires an embedded buffer declaration");
    }
  } else {
    if (buffers.length !== 1) fail("multiple-buffers", "multiple buffers are not allowed");
    const buffer = buffers[0];
    if (Object.prototype.hasOwnProperty.call(buffer, "uri")) {
      fail("external-buffer-uri", "external buffer uri is not allowed");
    }
    if (binLength === null) fail("buffer-not-embedded", "buffer is not the embedded GLB chunk");
    const declared = requiredInteger(buffer.byteLength, "buffers[0].byteLength", "buffer-not-embedded");
    if (declared < 0 || declared > binLength) {
      fail("buffer-not-embedded", "buffer is not the embedded GLB chunk");
    }
    bufferLength = declared;
  }

  const views = objectArray(root, "bufferViews");
  for (const view of views) viewRange(view, bufferLength);

  const nodes = objectArray(root, "nodes");
  const meshes = objectArray(root, "meshes");
  if (nodes.length > glbLimits.maxNodes) fail("too-many-nodes", "too many nodes");
  if (meshes.length > glbLimits.maxMeshes) fail("too-many-meshes", "too many meshes");
  const names = new Set();
  const uv = new Map();
  for (const [index, node] of nodes.entries()) {
    if (!Object.prototype.hasOwnProperty.call(node, "name")) continue;
    if (typeof node.name !== "string") {
      fail("node-name-not-string", `nodes[${index}].name must be a string`);
    }
    if (node.name.length === 0 || names.has(node.name)) {
      fail("empty-or-duplicate-node-name", "empty or duplicate node name");
    }
    names.add(node.name);
    uv.set(node.name, nodeUV(meshes, node));
  }

  const accessors = objectArray(root, "accessors");
  const accessorCounts = [];
  for (const [index, accessor] of accessors.entries()) {
    const count = requiredInteger(accessor.count, `accessors[${index}].count`, "invalid-accessor");
    if (count < 0) fail("invalid-accessor", "accessor count must be non-negative");
    const viewIndex = optionalInteger(
      accessor.bufferView,
      `accessors[${index}].bufferView`,
      "invalid-accessor",
    );
    if (viewIndex !== undefined && (viewIndex < 0 || viewIndex >= views.length)) {
      fail("invalid-accessor", "accessor bufferView out of bounds");
    }
    accessorCounts.push(count);
  }

  let triangles = 0;
  for (const [meshIndex, mesh] of meshes.entries()) {
    const primitives = mesh.primitives;
    if (primitives === undefined) continue;
    if (!Array.isArray(primitives)) {
      fail("malformed-glTF-json", `meshes[${meshIndex}].primitives must be an array`);
    }
    for (const [primitiveIndex, primitive] of primitives.entries()) {
      const prefix = `meshes[${meshIndex}].primitives[${primitiveIndex}]`;
      if (!isObject(primitive)) {
        fail("malformed-glTF-json", `${prefix} must be an object`);
      }
      const mode = optionalInteger(primitive.mode, `${prefix}.mode`, "invalid-primitive-mode") ?? 4;
      if (mode !== 4) fail("only-triangle-primitives", "only triangle primitives are allowed");
      if (primitive.attributes === undefined) {
        fail("invalid-primitive-accessor", `${prefix}.attributes is required`);
      }
      if (!isObject(primitive.attributes)) {
        fail("invalid-primitive-accessor", `${prefix}.attributes must be an object`);
      }
      let positionIndex = null;
      for (const [semantic, rawAccessor] of Object.entries(primitive.attributes)) {
        const accessorIndex = requiredInteger(
          rawAccessor,
          `${prefix}.attributes.${semantic}`,
          "invalid-primitive-accessor",
        );
        if (accessorIndex < 0 || accessorIndex >= accessors.length) {
          fail("invalid-primitive-accessor", "invalid primitive accessor");
        }
        if (semantic === "POSITION") positionIndex = accessorIndex;
      }
      const indices = optionalInteger(primitive.indices, `${prefix}.indices`, "invalid-primitive-accessor");
      const source = indices ?? positionIndex;
      if (source === null || source < 0 || source >= accessors.length) {
        fail("invalid-primitive-accessor", "invalid primitive accessor");
      }
      triangles += Math.floor(accessorCounts[source] / 3);
      if (triangles > glbLimits.maxTriangles) fail("too-many-triangles", "too many triangles");
    }
  }

  let textureBytes = 0;
  for (const [index, image] of objectArray(root, "images").entries()) {
    if (Object.prototype.hasOwnProperty.call(image, "uri")) {
      fail("external-image-uri", "external image uri is not allowed");
    }
    if (image.bufferView === undefined) {
      fail("image-must-reference-buffer-view", "image must reference an embedded bufferView");
    }
    const viewIndex = requiredInteger(
      image.bufferView,
      `images[${index}].bufferView`,
      "image-must-reference-buffer-view",
    );
    if (viewIndex < 0 || viewIndex >= views.length) {
      fail("image-must-reference-buffer-view", "image must reference an embedded bufferView");
    }
    const range = viewRange(views[viewIndex], bufferLength);
    if (binStart === null) fail("missing-bin-chunk", "missing BIN chunk");
    const bytes = glb.subarray(binStart + range.start, binStart + range.end);
    const size = embeddedImageSize(bytes);
    if (!size) fail("unreadable-embedded-image", "unreadable embedded image");
    if (size.width > glbLimits.maxTextureEdge || size.height > glbLimits.maxTextureEdge) {
      fail("texture-edge-exceeds-budget", "texture edge exceeds budget");
    }
    textureBytes += size.width * size.height * 4;
    if (textureBytes > glbLimits.maxDecodedTextureBytes) {
      fail("decoded-texture-budget-exceeded", "decoded texture budget exceeded");
    }
  }

  return {
    nodeNames: names,
    nodeUV: uv,
    meshCount: meshes.length,
    nodeCount: nodes.length,
    triangleCount: triangles,
    decodedTextureBytes: textureBytes,
  };
}

/**
 * 校验一个 GLB Buffer。抛出的 GLBError.code 是稳定标识，reason 与宿主
 * 预检文案保持一致，便于 CLI/宿主共用测试断言。
 */
export function inspectGLB(input) {
  const data = Buffer.isBuffer(input) ? input : Buffer.from(input);
  if (data.length > glbLimits.maxFileBytes) fail("glb-exceeds-byte-budget", "glb exceeds byte budget");
  if (data.length < 20) fail("glb-too-short", "glb too short");
  if (u32(data, 0) !== MAGIC || u32(data, 4) !== 2) {
    fail("not-glTF-2-binary", "not a glTF 2.0 binary");
  }
  if (u32(data, 8) !== data.length) fail("glb-length-mismatch", "glb length mismatch");

  let offset = 12;
  let chunkIndex = 0;
  let jsonBytes = null;
  let json = null;
  let binStart = null;
  let binLength = null;
  while (offset < data.length) {
    if (offset + 8 > data.length) fail("truncated-chunk-header", "truncated chunk header");
    const length = u32(data, offset);
    const type = u32(data, offset + 4);
    const start = offset + 8;
    // cgltf 按原始 length 推进；未对齐的长度会让两个解析器看到不同边界。
    if (length % 4 !== 0) fail("unaligned-chunk-length", "chunk length is not 4-byte aligned");
    if (length > data.length - start) fail("chunk-out-of-bounds", "chunk out of bounds");
    if (chunkIndex === 0) {
      if (type !== CHUNK_JSON) fail("first-chunk-must-be-json", "first chunk must be JSON");
      jsonBytes = data.subarray(start, start + length);
    } else if (chunkIndex === 1) {
      if (type !== CHUNK_BIN) fail("second-chunk-must-be-bin", "second chunk must be BIN");
      binStart = start;
      binLength = length;
    } else if (type === CHUNK_JSON) {
      fail("duplicate-json-chunk", "duplicate JSON chunk");
    } else if (type === CHUNK_BIN) {
      fail("duplicate-bin-chunk", "duplicate BIN chunk");
    }
    // 第三个及之后的未知 chunk 被 cgltf 忽略，这里只校验边界后跳过。
    offset = start + length;
    chunkIndex += 1;
  }
  if (jsonBytes === null) fail("missing-json-chunk", "missing JSON chunk");
  if (offset !== data.length) fail("glb-length-mismatch", "glb length mismatch");
  if (!hasSafeJSONNesting(jsonBytes)) {
    fail("json-nesting-too-deep", "glTF JSON is nested too deeply");
  }
  try {
    json = JSON.parse(jsonBytes.toString("utf8"));
  } catch {
    fail("malformed-glTF-json", "malformed glTF JSON");
  }
  if (!isObject(json)) fail("malformed-glTF-json", "malformed glTF JSON");
  return validate(json, data, binStart, binLength);
}
