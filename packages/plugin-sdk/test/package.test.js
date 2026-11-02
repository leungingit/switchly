import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  access,
  cp,
  mkdir,
  mkdtemp,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(testDirectory, "..");

async function packSDK(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-sdk-pack-"));
  t.after(() => rm(root, { recursive: true, force: true }));

  const packed = spawnSync(
    "npm",
    ["pack", packageDirectory, "--pack-destination", root, "--json"],
    { cwd: root, encoding: "utf8" },
  );
  assert.equal(packed.status, 0, packed.stderr);
  const filename = JSON.parse(packed.stdout)[0].filename;
  const tarball = path.join(root, filename);
  const extracted = path.join(root, "extracted");
  await mkdir(extracted);
  const unpacked = spawnSync("tar", ["-xzf", tarball, "-C", extracted], {
    encoding: "utf8",
  });
  assert.equal(unpacked.status, 0, unpacked.stderr);

  const packedPackage = path.join(extracted, "package");
  await access(path.join(packedPackage, "index.d.ts"));
  return { root, packedPackage };
}

test("npm pack 后的 SDK 可直接引用运行时代码且包含类型入口", async (t) => {
  const { packedPackage } = await packSDK(t);
  const moduleURL = pathToFileURL(path.join(packedPackage, "src", "index.js"));
  const sdk = await import(moduleURL.href);
  const plugin = sdk.definePlugin({
    render: (ctx) => [{
      slot: "titleAccessory",
      node: sdk.ui.badge({ value: String(ctx.storage) }),
    }],
  });
  assert.equal(globalThis.__switchlyPlugin, plugin);
});

test("npm pack 后的 SDK types 路径可由 tsc 解析", async (t) => {
  const tscVersion = spawnSync("tsc", ["--version"], { encoding: "utf8" });
  if (tscVersion.error?.code === "ENOENT") {
    t.skip("本机没有 tsc，已跳过打包后类型解析验证");
    return;
  }
  assert.equal(tscVersion.status, 0, tscVersion.stderr);
  const { root, packedPackage } = await packSDK(t);
  const nodeModules = path.join(root, "node_modules", "@switchly");
  const installedPackage = path.join(nodeModules, "plugin-sdk");
  await mkdir(nodeModules, { recursive: true });
  await cp(packedPackage, installedPackage, { recursive: true });
  await writeFile(path.join(root, "consumer.mts"), `
import {
  definePlugin,
  ui,
  type PluginContext,
  type PluginManifest,
  type PluginScene,
} from "@switchly/plugin-sdk";

const manifest: PluginManifest = {
  id: "com.example.types",
  name: { en: "Types" },
  version: "1",
  apiVersion: 2,
  matches: ["com.example.app"],
  permissions: [],
  entry: "main.js",
};

const scene: PluginScene = {
  key: "types",
  epoch: 0,
  width: 100,
  height: 100,
  layers: [],
};

definePlugin({
  async render(ctx: PluginContext) {
    const value = await ctx.storage.get("key");
    await ctx.storage.set("key", value);
    return [{ slot: "center", node: ui.scene(scene) }];
  },
});

void manifest;
`);
  const tsc = spawnSync("tsc", [
    "--noEmit",
    "--strict",
    "--target",
    "ES2022",
    "--module",
    "NodeNext",
    "--moduleResolution",
    "NodeNext",
    "consumer.mts",
  ], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(tsc.status, 0, `${tsc.stdout}\n${tsc.stderr}`);
});
