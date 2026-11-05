import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { runBaselineCommand } from "../src/baseline.js";
import { PngError, decodePng, encodePng } from "../src/png.js";

const ENVIRONMENT = {
  operatingSystemVersion: "27.0.0", architecture: "arm64", locale: "en", appearance: "light",
  displayScale: 2, rendererRevision: "sha256:aaa", glass: false, deterministicClock: true,
};

function image(width, height, paint = () => [20, 30, 40, 255]) {
  const rgba = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) rgba.set(paint(x, y), (y * width + x) * 4);
  return { width, height, rgba };
}

async function workspace(t) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), "switchly-baseline-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

async function makeRun(root, name, { img = image(8, 6), environment = {}, report = {} } = {}) {
  const directory = path.join(root, name);
  await mkdir(directory, { recursive: true });
  const body = {
    schemaVersion: 1, status: "passed", scenarioID: "scn", pluginID: "com.example.p", pluginVersion: "1",
    packageHash: "sha256:pkg1", artifacts: { report: "report.json", screenshot: "preview.png" },
    versions: { toolVersion: "0.1.0" }, environment: { ...ENVIRONMENT, ...environment }, ...report,
  };
  await writeFile(path.join(directory, "report.json"), JSON.stringify(body));
  await writeFile(path.join(directory, "preview.png"), encodePng(img));
  return directory;
}

async function run(args) {
  let stdout = ""; let stderr = "";
  const code = await runBaselineCommand([...args, "--json"], {
    stdout: { write: (chunk) => { stdout += chunk; } }, stderr: { write: (chunk) => { stderr += chunk; } },
  });
  return { code, result: JSON.parse(stdout), stderr, stdout };
}

test("PNG 编解码往返一致，并拒绝损坏或不支持的输入", () => {
  const original = image(5, 4, (x, y) => [x * 40, y * 50, 7, 255]);
  const decoded = decodePng(encodePng(original));
  assert.equal(decoded.width, 5);
  assert.deepEqual([...decoded.rgba], [...original.rgba]);
  const bad = encodePng(original);
  bad[bad.length - 20] ^= 0xff; // 破坏 IDAT 内容，CRC 必须失败
  assert.throws(() => decodePng(bad), (error) => error instanceof PngError && error.code === "invalid-png");
  assert.throws(() => decodePng(Buffer.from("not a png")), PngError);
});

test("accept 只接受确定时钟且非玻璃的 passed run，且不覆盖已有基线", async (t) => {
  const root = await workspace(t);
  const baselines = path.join(root, "baselines");
  const glass = await makeRun(root, "glass", { environment: { glass: true } });
  assert.equal((await run(["accept", glass, "--baseline-dir", baselines])).result.error.code, "not-a-stable-baseline");
  const live = await makeRun(root, "live", { environment: { deterministicClock: false } });
  assert.equal((await run(["accept", live, "--baseline-dir", baselines])).result.error.code, "not-a-stable-baseline");
  const failed = await makeRun(root, "failed", { report: { status: "failed" } });
  assert.equal((await run(["accept", failed, "--baseline-dir", baselines])).result.error.code, "run-not-passed");
  const unsafe = await makeRun(root, "unsafe", { report: { scenarioID: "../escape" } });
  assert.equal((await run(["accept", unsafe, "--baseline-dir", baselines])).result.error.code, "identity-unsafe");

  const good = await makeRun(root, "good");
  const first = await run(["accept", good, "--baseline-dir", baselines]);
  assert.equal(first.code, 0);
  assert.equal(first.result.replaced, false);
  const again = await run(["accept", good, "--baseline-dir", baselines]);
  assert.equal(again.code, 1);
  assert.equal(again.result.error.code, "baseline-exists");
  assert.equal((await run(["accept", good, "--baseline-dir", baselines, "--replace"])).result.replaced, true);
  const meta = JSON.parse(await readFile(path.join(baselines, "com.example.p__scn", "baseline.json"), "utf8"));
  assert.equal(meta.provenance.packageHash, "sha256:pkg1");
  assert.equal(meta.fingerprint.osMajor, "27");
});

test("compare：一致通过；改动区域被精确定位并生成差异图", async (t) => {
  const root = await workspace(t);
  const baselines = path.join(root, "baselines");
  await run(["accept", await makeRun(root, "base"), "--baseline-dir", baselines]);

  const same = await run(["compare", await makeRun(root, "same"), "--baseline-dir", baselines, "--out", path.join(root, "o1")]);
  assert.equal(same.code, 0);
  assert.equal(same.result.diff.pixels, 0);
  assert.deepEqual(await readdir(path.join(root, "o1")), ["compare-report.json"]);

  const changed = image(8, 6, (x, y) => (x >= 2 && x < 5 && y >= 1 && y < 3 ? [200, 30, 40, 255] : [20, 30, 40, 255]));
  const diff = await run(["compare", await makeRun(root, "changed", { img: changed, report: { packageHash: "sha256:pkg2" } }),
    "--baseline-dir", baselines, "--out", path.join(root, "o2")]);
  assert.equal(diff.code, 1);
  assert.equal(diff.result.failure.code, "visual-diff");
  assert.equal(diff.result.diff.pixels, 6);
  assert.deepEqual(diff.result.diff.boundingBox, { x: 2, y: 1, width: 3, height: 2 });
  assert.equal(diff.result.diff.maxChannelDifference, 180);
  assert.equal(diff.result.packageChanged, true, "包哈希只作为溯源字段，不影响基线身份");
  const diffImage = decodePng(await readFile(path.join(root, "o2", "diff.png")));
  assert.deepEqual([...diffImage.rgba.slice((1 * 8 + 2) * 4, (1 * 8 + 2) * 4 + 4)], [255, 0, 0, 255]);
});

test("compare：容差必须显式给出并记录；默认零容差", async (t) => {
  const root = await workspace(t);
  const baselines = path.join(root, "baselines");
  await run(["accept", await makeRun(root, "base"), "--baseline-dir", baselines]);
  const subtle = await makeRun(root, "subtle", { img: image(8, 6, () => [23, 30, 40, 255]) });
  assert.equal((await run(["compare", subtle, "--baseline-dir", baselines, "--out", path.join(root, "o1")])).code, 1);
  const tolerated = await run(["compare", subtle, "--baseline-dir", baselines, "--out", path.join(root, "o2"), "--tolerance", "3"]);
  assert.equal(tolerated.code, 0);
  assert.equal(tolerated.result.tolerance, 3);
  assert.equal((await run(["compare", subtle, "--baseline-dir", baselines, "--out", path.join(root, "o3"), "--tolerance", "300"])).code, 2);
});

test("compare：环境指纹不兼容时拒绝比较并列出字段，且不生成差异图", async (t) => {
  const root = await workspace(t);
  const baselines = path.join(root, "baselines");
  await run(["accept", await makeRun(root, "base"), "--baseline-dir", baselines]);
  const other = await makeRun(root, "other", {
    img: image(8, 6, () => [1, 2, 3, 255]),
    environment: { rendererRevision: "sha256:bbb", displayScale: 1, operatingSystemVersion: "28.0.0" },
  });
  const outcome = await run(["compare", other, "--baseline-dir", baselines, "--out", path.join(root, "o")]);
  assert.equal(outcome.code, 4);
  assert.equal(outcome.result.status, "environment-error");
  assert.equal(outcome.result.error.code, "incompatible-environment");
  assert.deepEqual(outcome.result.mismatchedFields.sort(), ["displayScale", "osMajor", "rendererRevision"]);
  await assert.rejects(readdir(path.join(root, "o")));
});

test("compare：尺寸变化、缺失基线、篡改基线、非空输出目录分别报告", async (t) => {
  const root = await workspace(t);
  const baselines = path.join(root, "baselines");
  const missing = await run(["compare", await makeRun(root, "none"), "--baseline-dir", baselines, "--out", path.join(root, "m")]);
  assert.equal(missing.result.error.code, "baseline-missing");

  await run(["accept", await makeRun(root, "base"), "--baseline-dir", baselines]);
  const resized = await run(["compare", await makeRun(root, "wide", { img: image(9, 6) }), "--baseline-dir", baselines,
    "--out", path.join(root, "s")]);
  assert.equal(resized.result.failure.code, "size-changed");
  assert.equal(resized.code, 1);

  const occupied = path.join(root, "occupied");
  await mkdir(occupied);
  await writeFile(path.join(occupied, "keep"), "x");
  const blocked = await run(["compare", await makeRun(root, "same2"), "--baseline-dir", baselines, "--out", occupied]);
  assert.equal(blocked.result.error.code, "output-not-empty");

  await writeFile(path.join(baselines, "com.example.p__scn", "baseline.png"), encodePng(image(8, 6, () => [9, 9, 9, 255])));
  const tampered = await run(["compare", await makeRun(root, "same3"), "--baseline-dir", baselines, "--out", path.join(root, "t")]);
  assert.equal(tampered.result.error.code, "baseline-invalid");
});

test("参数错误返回 2 且不读取文件", async () => {
  assert.equal((await run(["frobnicate"])).code, 2);
  assert.equal((await run(["accept", "x"])).code, 2);
  assert.equal((await run(["compare", "x", "--baseline-dir", "y"])).code, 2);
  assert.equal((await run(["accept", "x", "--baseline-dir", "y", "--bogus"])).code, 2);
});
