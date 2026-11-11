import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  truncate,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  GLBError,
  glbLimits,
  inspectGLB,
} from "../src/glb.js";
import { crc32, encodePng } from "../src/png.js";
import { validatePluginDirectory } from "../src/validate.js";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const scene3DFixtures = path.join(repositoryRoot, "Tests/Fixtures/Scene3D");
const publicAssets = path.join(
  repositoryRoot,
  "docs/plugins/assets/3d-loading-probe-2026-11-06",
);

const JSON_CHUNK = 0x4e4f534a;
const BIN_CHUNK = 0x004e4942;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const baseGLTF = {
  asset: { version: "2.0" },
  buffers: [{ byteLength: 64 }],
  bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: 32 }],
  nodes: [{ name: "mesh_screen" }, { name: "mesh_wheel_play" }],
};

function cloneBase() {
  return JSON.parse(JSON.stringify(baseGLTF));
}

function chunk(type, body, padByte = 0) {
  const paddedLength = (body.length + 3) & ~3;
  const out = Buffer.alloc(8 + paddedLength, padByte);
  out.writeUInt32LE(paddedLength, 0);
  out.writeUInt32LE(type, 4);
  body.copy(out, 8);
  return out;
}

function makeGLBFromJSONText(jsonText, bin = null) {
  const jsonChunk = chunk(JSON_CHUNK, Buffer.from(jsonText, "utf8"), 0x20);
  const binChunk = bin === null ? Buffer.alloc(0) : chunk(BIN_CHUNK, bin);
  const header = Buffer.alloc(12);
  header.writeUInt32LE(0x46546c67, 0);
  header.writeUInt32LE(2, 4);
  header.writeUInt32LE(12 + jsonChunk.length + binChunk.length, 8);
  return Buffer.concat([header, jsonChunk, binChunk]);
}

function makeGLB(root, bin = null) {
  return makeGLBFromJSONText(JSON.stringify(root), bin);
}

function padJSON(text) {
  const bytes = Buffer.from(text, "utf8");
  const padded = Buffer.alloc((bytes.length + 3) & ~3, 0x20);
  bytes.copy(padded);
  return padded;
}

function rawContainer(chunks) {
  const body = Buffer.concat(chunks.map(({ type, payload }) => {
    const header = Buffer.alloc(8);
    header.writeUInt32LE(payload.length, 0);
    header.writeUInt32LE(type, 4);
    return Buffer.concat([header, payload]);
  }));
  const header = Buffer.alloc(12);
  header.writeUInt32LE(0x46546c67, 0);
  header.writeUInt32LE(2, 4);
  header.writeUInt32LE(12 + body.length, 8);
  return Buffer.concat([header, body]);
}

function assertGLBCode(data, code, reason = null) {
  assert.throws(
    () => inspectGLB(data),
    (error) => {
      assert(error instanceof GLBError, `期望 GLBError，实际 ${error}`);
      assert.equal(error.code, code);
      if (reason !== null) assert.equal(error.reason, reason);
      return true;
    },
  );
}

function pngChunk(type, body) {
  const out = Buffer.alloc(12 + body.length);
  out.writeUInt32BE(body.length, 0);
  out.write(type, 4, "latin1");
  body.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + body.length)), 8 + body.length);
  return out;
}

function syntheticPNG(width, height) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    PNG_SIGNATURE,
    pngChunk("IHDR", header),
    pngChunk("IDAT", Buffer.from([0])),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function syntheticJPEG(width, height) {
  return Buffer.from([
    0xff, 0xd8,
    0xff, 0xe0, 0x00, 0x02,
    0xff, 0xc0, 0x00, 0x07,
    0x08,
    height >> 8, height & 0xff,
    width >> 8, width & 0xff,
    0x01,
  ]);
}

function imageGLB(images) {
  const bin = Buffer.concat(images.map((image) => image.bytes));
  const bufferViews = [];
  let offset = 0;
  for (const image of images) {
    bufferViews.push({ buffer: 0, byteOffset: offset, byteLength: image.bytes.length });
    offset += image.bytes.length;
  }
  return makeGLB({
    asset: { version: "2.0" },
    buffers: [{ byteLength: bin.length }],
    bufferViews,
    images: images.map((_, index) => ({ bufferView: index })),
  }, bin);
}

async function makePlugin(name = "com.example.demo") {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-plugin-glb-"));
  const plugin = path.join(root, name);
  await mkdir(path.join(plugin, "assets"), { recursive: true });
  await mkdir(path.join(plugin, "locales"), { recursive: true });
  await writeFile(path.join(plugin, "assets", "icon.png"), "not-a-real-png");
  await writeFile(
    path.join(plugin, "main.js"),
    `globalThis.__switchlyPlugin = { render() {
      return [{ slot: "center", node: { type: "image",
        source: { pluginAsset: "assets/icon.png" } } }];
    } };\n`,
  );
  await writeFile(
    path.join(plugin, "locales", "en.json"),
    JSON.stringify({ Play: "Play" }),
  );
  await writeFile(
    path.join(plugin, "locales", "zh-Hans.json"),
    JSON.stringify({ Play: "播放" }),
  );
  await writeFile(
    path.join(plugin, "manifest.json"),
    JSON.stringify({
      id: name,
      name: { en: "Demo", "zh-Hans": "示例" },
      version: "1",
      apiVersion: 2,
      matches: ["com.example.app"],
      permissions: [],
      entry: "main.js",
    }, null, 2),
  );
  return { root, plugin };
}

function cleanup(t, root) {
  t.after(() => rm(root, { recursive: true, force: true }));
}

test("合法公共 GLB 夹具通过预检并报告节点 UV", async () => {
  const cases = [
    ["ipod-source-geometry.glb", "mesh_screen", 12],
    ["barometer.glb", "mesh_weather_screen", 4],
  ];
  for (const [file, screenNode, expectedNodes] of cases) {
    const report = inspectGLB(await readFile(path.join(publicAssets, file)));
    assert.equal(report.nodeCount, expectedNodes);
    assert.equal(report.nodeUV.get(screenNode), true);
    assert(report.nodeCount <= glbLimits.maxNodes);
    assert(report.meshCount <= glbLimits.maxMeshes);
    assert(report.triangleCount <= glbLimits.maxTriangles);
    assert(report.decodedTextureBytes <= glbLimits.maxDecodedTextureBytes);
  }
  const ipod = inspectGLB(
    await readFile(path.join(publicAssets, "ipod-source-geometry.glb")),
  );
  assert.equal(ipod.nodeUV.get("mesh_wheel_play"), true);
});

test("插件包校验通过真实 Scene3D 资产并拒绝公共超预算夹具", async (t) => {
  const { root, plugin } = await makePlugin();
  cleanup(t, root);
  for (const file of ["ipod-source-geometry.glb", "barometer.glb"]) {
    await writeFile(
      path.join(plugin, "assets", file),
      await readFile(path.join(publicAssets, file)),
    );
  }
  const valid = await validatePluginDirectory(plugin);
  assert.equal(valid.ok, true, valid.errors.join("\n"));

  await writeFile(
    path.join(plugin, "assets", "over-budget.glb"),
    await readFile(path.join(scene3DFixtures, "invalid/over-budget.glb")),
  );
  const invalid = await validatePluginDirectory(plugin);
  assert.equal(invalid.ok, false);
  assert(invalid.errors.some((error) => error.includes("too many nodes")
    && error.includes("assets/over-budget.glb")));
});

test("外部、绝对与网络 URI 在 buffer 和 image 中都被拒绝", () => {
  for (const uri of [
    "../../sentinel.png",
    "/tmp/sentinel.png",
    "https://example.invalid/sentinel.png",
  ]) {
    const externalBuffer = makeGLB({ ...cloneBase(), buffers: [{ byteLength: 1, uri }] });
    assertGLBCode(externalBuffer, "external-buffer-uri", "external buffer uri is not allowed");

    const externalImage = makeGLB({
      asset: { version: "2.0" },
      images: [{ uri }],
    });
    assertGLBCode(externalImage, "external-image-uri", "external image uri is not allowed");
  }
});

test("未批准扩展与畸形 JSON 被拒绝，批准扩展可通过", () => {
  for (const key of ["extensionsUsed", "extensionsRequired"]) {
    for (const extension of ["KHR_draco_mesh_compression", "KHR_texture_basisu"]) {
      assertGLBCode(
        makeGLB({ ...cloneBase(), [key]: [extension] }),
        "extension-not-allowed",
        `extension not allowed: ${extension}`,
      );
    }
  }
  const approved = makeGLB({
    ...cloneBase(),
    extensionsUsed: [
      "KHR_materials_clearcoat",
      "KHR_materials_emissive_strength",
      "KHR_materials_unlit",
    ],
  }, Buffer.alloc(64));
  assert.equal(inspectGLB(approved).nodeCount, 2);

  assertGLBCode(
    makeGLBFromJSONText('{"asset":', Buffer.alloc(64)),
    "malformed-glTF-json",
    "malformed glTF JSON",
  );
});

test("bufferView 必须引用内嵌 BIN 且不越界", () => {
  const bin = Buffer.alloc(64);
  assertGLBCode(
    makeGLB({
      ...cloneBase(),
      bufferViews: [{ buffer: 1, byteOffset: 0, byteLength: 1 }],
    }, bin),
    "invalid-buffer-view",
    "invalid bufferView",
  );
  assertGLBCode(
    makeGLB({
      ...cloneBase(),
      bufferViews: [{ buffer: 0, byteOffset: 32, byteLength: 33 }],
    }, bin),
    "buffer-view-out-of-bounds",
    "bufferView out of bounds",
  );
  assertGLBCode(
    makeGLB({
      ...cloneBase(),
      buffers: [{ byteLength: 65 }],
    }, bin),
    "buffer-not-embedded",
    "buffer is not the embedded GLB chunk",
  );
});

test("空名与重复节点名被拒绝", () => {
  assertGLBCode(
    makeGLB({ ...cloneBase(), nodes: [{ name: "" }] }, Buffer.alloc(64)),
    "empty-or-duplicate-node-name",
    "empty or duplicate node name",
  );
  assertGLBCode(
    makeGLB({
      ...cloneBase(),
      nodes: [{ name: "mesh_screen" }, { name: "mesh_screen" }],
    }, Buffer.alloc(64)),
    "empty-or-duplicate-node-name",
    "empty or duplicate node name",
  );
});

test("节点、网格与三角形预算按宿主硬值执行", () => {
  const maxNodes = Array.from(
    { length: glbLimits.maxNodes + 1 },
    (_, index) => ({ name: `node_${index}` }),
  );
  assertGLBCode(
    makeGLB({ ...cloneBase(), nodes: maxNodes }, Buffer.alloc(64)),
    "too-many-nodes",
    "too many nodes",
  );

  const maxMeshes = Array.from({ length: glbLimits.maxMeshes + 1 }, () => ({}));
  assertGLBCode(
    makeGLB({ ...cloneBase(), meshes: maxMeshes }, Buffer.alloc(64)),
    "too-many-meshes",
    "too many meshes",
  );

  const overBudget = makeGLB({
    asset: { version: "2.0" },
    meshes: [{ primitives: [{ attributes: { POSITION: 0 } }] }],
    accessors: [{ count: glbLimits.maxTriangles * 3 + 3 }],
  });
  assertGLBCode(overBudget, "too-many-triangles", "too many triangles");

  const atBudget = makeGLB({
    asset: { version: "2.0" },
    meshes: [{ primitives: [{ attributes: { POSITION: 0 } }] }],
    accessors: [{ count: glbLimits.maxTriangles * 3 }],
  });
  assert.equal(inspectGLB(atBudget).triangleCount, glbLimits.maxTriangles);
});

test("仅允许三角形 primitive 且 accessor 必须有效", () => {
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      meshes: [{ primitives: [{ mode: 1, attributes: { POSITION: 0 } }] }],
      accessors: [{ count: 3 }],
    }),
    "only-triangle-primitives",
    "only triangle primitives are allowed",
  );
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      meshes: [{ primitives: [{ attributes: { POSITION: 4 } }] }],
      accessors: [{ count: 3 }],
    }),
    "invalid-primitive-accessor",
    "invalid primitive accessor",
  );
});

test("无 UV 屏幕节点不会被当作包级错误，但报告会标记为 false", () => {
  const root = {
    asset: { version: "2.0" },
    meshes: [{
      primitives: [{ attributes: { POSITION: 0 }, indices: 0 }],
    }],
    accessors: [{ count: 3 }, { count: 3 }],
    nodes: [{ name: "mesh_screen", mesh: 0 }],
  };
  const report = inspectGLB(makeGLB(root));
  assert.equal(report.nodeUV.get("mesh_screen"), false);

  root.meshes[0].primitives[0].attributes.TEXCOORD_0 = 1;
  assert.equal(inspectGLB(makeGLB(root)).nodeUV.get("mesh_screen"), true);
});

test("内嵌图片头、纹理边长与累计解码预算被检查", () => {
  const small = syntheticPNG(1, 1);
  assert.equal(inspectGLB(imageGLB([{ bytes: small }])).decodedTextureBytes, 4);
  assert.equal(
    inspectGLB(imageGLB([{ bytes: syntheticJPEG(1, 1) }])).nodeCount,
    0,
  );

  const edge = syntheticPNG(glbLimits.maxTextureEdge + 1, 1);
  assertGLBCode(
    imageGLB([{ bytes: edge }]),
    "texture-edge-exceeds-budget",
    "texture edge exceeds budget",
  );

  const huge = syntheticPNG(glbLimits.maxTextureEdge, glbLimits.maxTextureEdge);
  assertGLBCode(
    imageGLB([{ bytes: huge }, { bytes: huge }, { bytes: huge }]),
    "decoded-texture-budget-exceeded",
    "decoded texture budget exceeded",
  );

  assertGLBCode(
    imageGLB([{ bytes: Buffer.from("not-an-image") }]),
    "unreadable-embedded-image",
    "unreadable embedded image",
  );

  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      images: [{ mimeType: "image/png" }],
    }),
    "image-must-reference-buffer-view",
    "image must reference an embedded bufferView",
  );
});

test("缺失内嵌 buffer 与破损容器被拒绝", () => {
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      images: [{ bufferView: 0 }],
      bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: 0 }],
    }),
    "buffer-view-without-buffer",
    "bufferView requires an embedded buffer",
  );

  assertGLBCode(Buffer.alloc(19), "glb-too-short", "glb too short");
  assertGLBCode(Buffer.alloc(20), "not-glTF-2-binary", "not a glTF 2.0 binary");
  assertGLBCode(
    Buffer.alloc(glbLimits.maxFileBytes + 1),
    "glb-exceeds-byte-budget",
    "glb exceeds byte budget",
  );

  const valid = makeGLB(cloneBase(), Buffer.alloc(64));
  const lengthMismatch = Buffer.from(valid);
  lengthMismatch.writeUInt32LE(valid.length + 4, 8);
  assertGLBCode(lengthMismatch, "glb-length-mismatch", "glb length mismatch");

  const wrongVersion = Buffer.from(valid);
  wrongVersion.writeUInt32LE(1, 4);
  assertGLBCode(wrongVersion, "not-glTF-2-binary", "not a glTF 2.0 binary");

  const truncatedHeader = Buffer.alloc(24);
  truncatedHeader.writeUInt32LE(0x46546c67, 0);
  truncatedHeader.writeUInt32LE(2, 4);
  truncatedHeader.writeUInt32LE(24, 8);
  truncatedHeader.writeUInt32LE(0, 12);
  truncatedHeader.writeUInt32LE(JSON_CHUNK, 16);
  assertGLBCode(
    truncatedHeader,
    "truncated-chunk-header",
    "truncated chunk header",
  );

  const outOfBounds = Buffer.alloc(20);
  outOfBounds.writeUInt32LE(0x46546c67, 0);
  outOfBounds.writeUInt32LE(2, 4);
  outOfBounds.writeUInt32LE(20, 8);
  outOfBounds.writeUInt32LE(100, 12);
  outOfBounds.writeUInt32LE(JSON_CHUNK, 16);
  assertGLBCode(outOfBounds, "chunk-out-of-bounds", "chunk out of bounds");

  const firstNotJSON = Buffer.alloc(20);
  firstNotJSON.writeUInt32LE(0x46546c67, 0);
  firstNotJSON.writeUInt32LE(2, 4);
  firstNotJSON.writeUInt32LE(20, 8);
  firstNotJSON.writeUInt32LE(0, 12);
  firstNotJSON.writeUInt32LE(BIN_CHUNK, 16);
  assertGLBCode(
    firstNotJSON,
    "first-chunk-must-be-json",
    "first chunk must be JSON",
  );
});

test("chunk 顺序、4 字节对齐与重复声明与宿主一致", () => {
  const json = padJSON(JSON.stringify(baseGLTF));
  assertGLBCode(
    rawContainer([{ type: JSON_CHUNK, payload: Buffer.from('{"asset":{}} ') }]),
    "unaligned-chunk-length",
    "chunk length is not 4-byte aligned",
  );
  assertGLBCode(
    rawContainer([
      { type: JSON_CHUNK, payload: json },
      { type: 0xdeadbeef, payload: Buffer.alloc(4) },
    ]),
    "second-chunk-must-be-bin",
    "second chunk must be BIN",
  );
  assertGLBCode(
    rawContainer([
      { type: JSON_CHUNK, payload: json },
      { type: BIN_CHUNK, payload: Buffer.alloc(64) },
      { type: JSON_CHUNK, payload: Buffer.alloc(4) },
    ]),
    "duplicate-json-chunk",
    "duplicate JSON chunk",
  );
  assertGLBCode(
    rawContainer([
      { type: JSON_CHUNK, payload: json },
      { type: BIN_CHUNK, payload: Buffer.alloc(64) },
      { type: BIN_CHUNK, payload: Buffer.alloc(4) },
    ]),
    "duplicate-bin-chunk",
    "duplicate BIN chunk",
  );
  assertGLBCode(
    rawContainer([
      { type: JSON_CHUNK, payload: json },
      { type: BIN_CHUNK, payload: Buffer.alloc(3) },
    ]),
    "unaligned-chunk-length",
    "chunk length is not 4-byte aligned",
  );
  assert.equal(inspectGLB(rawContainer([
    { type: JSON_CHUNK, payload: json },
    { type: BIN_CHUNK, payload: Buffer.alloc(64) },
    { type: 0xdeadbeef, payload: Buffer.alloc(4) },
  ])).nodeCount, 2);
});

test("BIN chunk 与 buffer 声明必须一致", () => {
  assertGLBCode(
    makeGLB({ asset: { version: "2.0" } }, Buffer.alloc(64)),
    "unexpected-bin-chunk",
    "BIN chunk requires an embedded buffer declaration",
  );
  assertGLBCode(
    makeGLB({ ...cloneBase(), buffers: [{ byteLength: 96 }] }, Buffer.alloc(64)),
    "buffer-not-embedded",
    "buffer is not the embedded GLB chunk",
  );
  assertGLBCode(
    makeGLB({ ...cloneBase(), buffers: [{ byteLength: 16 }, { byteLength: 16 }] }, Buffer.alloc(64)),
    "multiple-buffers",
    "multiple buffers are not allowed",
  );
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      bufferViews: [{ buffer: 0, byteLength: 1 }],
    }),
    "buffer-view-without-buffer",
    "bufferView requires an embedded buffer",
  );
  assert.equal(inspectGLB(makeGLB({ asset: { version: "2.0" } })).nodeCount, 0);
});

test("JSON 容器类型与数值类型必须严格", () => {
  for (const [key, value, reason] of [
    ["nodes", "n", "nodes must be an array"],
    ["nodes", [1], "nodes must contain objects"],
    ["meshes", [1], "meshes must contain objects"],
    ["accessors", "x", "accessors must be an array"],
    ["bufferViews", "x", "bufferViews must be an array"],
    ["buffers", "x", "buffers must be an array"],
    ["images", [1], "images must contain objects"],
    ["extensionsUsed", [1], "extensionsUsed must contain strings"],
  ]) {
    assertGLBCode(
      makeGLB({ ...cloneBase(), [key]: value }, Buffer.alloc(64)),
      "malformed-glTF-json",
      reason,
    );
  }

  assertGLBCode(
    makeGLB({ ...cloneBase(), buffers: [{ byteLength: "64" }] }, Buffer.alloc(64)),
    "buffer-not-embedded",
    "buffers[0].byteLength must be a JSON integer",
  );
  for (const view of [
    { buffer: true, byteLength: 32 },
    { buffer: 0, byteLength: 32, byteOffset: "0" },
    { buffer: 0, byteLength: "32" },
  ]) {
    assertGLBCode(
      makeGLB({ ...cloneBase(), bufferViews: [view] }, Buffer.alloc(64)),
      "invalid-buffer-view",
    );
  }
  assertGLBCode(
    makeGLB({ ...cloneBase(), nodes: [{ name: 7 }] }, Buffer.alloc(64)),
    "node-name-not-string",
    "nodes[0].name must be a string",
  );
  assertGLBCode(
    makeGLB({ asset: { version: "2.0" }, images: [{ bufferView: "0" }] }),
    "image-must-reference-buffer-view",
    "images[0].bufferView must be a JSON integer",
  );
});

test("accessor 与 primitive 的类型、引用不能回退", () => {
  for (const [accessor, reason] of [
    [{ count: 3.5 }, "accessors[0].count must be a JSON integer"],
    [{ count: true }, "accessors[0].count must be a JSON integer"],
    [{ count: 3, bufferView: true }, "accessors[0].bufferView must be a JSON integer"],
    [{ bufferView: 0 }, "accessors[0].count is required"],
    [{ count: -1 }, "accessor count must be non-negative"],
    [{ count: 3, bufferView: 4 }, "accessor bufferView out of bounds"],
  ]) {
    assertGLBCode(
      makeGLB({ asset: { version: "2.0" }, accessors: [accessor] }),
      "invalid-accessor",
      reason,
    );
  }
  // Int.max 的 JSON 数字经 Double 会变成 2^63，宿主按不可表示的大数拒绝。
  assertGLBCode(
    makeGLBFromJSONText('{"asset":{"version":"2.0"},"accessors":[{"count":9223372036854775807}]}'),
    "invalid-accessor",
    "accessors[0].count must be a JSON integer",
  );

  const withPrimitive = (primitive) => makeGLB({
    asset: { version: "2.0" },
    accessors: [{ count: 3 }],
    meshes: [{ primitives: [primitive] }],
  });
  assertGLBCode(
    withPrimitive({ mode: "4", attributes: { POSITION: 0 } }),
    "invalid-primitive-mode",
    "meshes[0].primitives[0].mode must be a JSON integer",
  );
  assertGLBCode(
    withPrimitive({ attributes: { POSITION: "0" } }),
    "invalid-primitive-accessor",
    "meshes[0].primitives[0].attributes.POSITION must be a JSON integer",
  );
  assertGLBCode(
    withPrimitive({ attributes: { POSITION: 9 } }),
    "invalid-primitive-accessor",
    "invalid primitive accessor",
  );
  // indices 类型错误不能静默回退到 POSITION。
  assertGLBCode(
    withPrimitive({ indices: "0", attributes: { POSITION: 0 } }),
    "invalid-primitive-accessor",
    "meshes[0].primitives[0].indices must be a JSON integer",
  );
  assertGLBCode(
    withPrimitive({ attributes: { NORMAL: 0 } }),
    "invalid-primitive-accessor",
    "invalid primitive accessor",
  );
  assertGLBCode(
    withPrimitive({}),
    "invalid-primitive-accessor",
    "meshes[0].primitives[0].attributes is required",
  );
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      meshes: [{ primitives: [1] }],
    }),
    "malformed-glTF-json",
    "meshes[0].primitives[0] must be an object",
  );
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      meshes: [{ primitives: "x" }],
    }),
    "malformed-glTF-json",
    "meshes[0].primitives must be an array",
  );
});

test("递归扩展白名单、extras 豁免与 JSON 深度受限", () => {
  assertGLBCode(
    makeGLB({
      asset: { version: "2.0" },
      accessors: [{ count: 3 }],
      meshes: [{
        primitives: [{
          attributes: { POSITION: 0 },
          extensions: { KHR_draco_mesh_compression: {} },
        }],
      }],
    }),
    "extension-not-allowed",
    "extension not allowed: KHR_draco_mesh_compression",
  );
  assert.equal(
    inspectGLB(makeGLB({
      ...cloneBase(),
      extensionsUsed: ["KHR_materials_unlit"],
      materials: [{ extensions: { KHR_materials_unlit: {} } }],
    }, Buffer.alloc(64))).nodeCount,
    2,
  );
  // extras 是任意 JSON，其中同名键不能触发扩展检查。
  assert.equal(
    inspectGLB(makeGLB({
      ...cloneBase(),
      nodes: [{
        name: "mesh_screen",
        extras: { extensions: { vendor: {} } },
      }],
    }, Buffer.alloc(64))).nodeCount,
    1,
  );
  assertGLBCode(
    makeGLB({ ...cloneBase(), extensions: "x" }, Buffer.alloc(64)),
    "malformed-glTF-json",
    "extensions must be an object",
  );

  const depth = glbLimits.maxJSONDepth + 4;
  const nested = "[".repeat(depth) + "]".repeat(depth);
  assertGLBCode(
    makeGLBFromJSONText(`{"asset":{"version":"2.0"},"extras":${nested}}`),
    "json-nesting-too-deep",
    "glTF JSON is nested too deeply",
  );
  assert.equal(
    inspectGLB(makeGLBFromJSONText('{"asset":{"version":"2.0"},"extras":[[[]]]}')).nodeCount,
    0,
  );
});

test("插件包扫描所有 GLB，符号链接与文件预算均被拒绝", async (t) => {
  const linked = await makePlugin("com.example.linked");
  cleanup(t, linked.root);
  await symlink(
    path.join(publicAssets, "barometer.glb"),
    path.join(linked.plugin, "assets", "linked.glb"),
  );
  const linkedResult = await validatePluginDirectory(linked.plugin);
  assert.equal(linkedResult.ok, false);
  assert(linkedResult.errors.some((error) => error.includes("禁止符号链接")));
  assert(!linkedResult.errors.some((error) => error.includes("3D 资产预检失败")));

  const oversized = await makePlugin("com.example.oversized");
  cleanup(t, oversized.root);
  const model = path.join(oversized.plugin, "assets", "huge.glb");
  await writeFile(model, "");
  await truncate(model, glbLimits.maxFileBytes + 1);
  const oversizedResult = await validatePluginDirectory(oversized.plugin);
  assert.equal(oversizedResult.ok, false);
  assert(oversizedResult.errors.some((error) => error.includes("glb-exceeds-byte-budget")
    && error.includes("assets/huge.glb")));
});
