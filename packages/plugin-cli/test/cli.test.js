import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const cliPath = path.resolve(testDirectory, "../bin/switchly-plugin.js");

async function makePlugin() {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-plugin-cli-"));
  const plugin = path.join(root, "com.example.demo");
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
    path.join(plugin, "locales", "zh-Hans.json"),
    JSON.stringify({ Play: "播放" }),
  );
  await writeFile(
    path.join(plugin, "manifest.json"),
    JSON.stringify({
      id: "com.example.demo",
      name: { en: "Demo", "zh-Hans": "示例" },
      version: "1",
      apiVersion: 2,
      matches: ["com.example.app"],
      permissions: [],
      entry: "main.js",
      settings: [
        { key: "show", title: { en: "Show" }, default: true },
        {
          key: "mode",
          type: "select",
          title: { en: "Mode" },
          default: "a",
          options: [{ value: "a", title: { en: "A" } }],
        },
      ],
    }, null, 2),
  );
  return { root, plugin };
}

test("api describe --json 输出机器能力清单", () => {
  const output = execFileSync(process.execPath, [cliPath, "api", "describe", "--json"], {
    encoding: "utf8",
  });
  const capabilities = JSON.parse(output);
  assert.deepEqual(capabilities.apiVersions.supported, [1, 2]);
  const fsFeature = capabilities.features.find((feature) => feature.id === "ctx.fs");
  const storageFeature = capabilities.features.find((feature) => feature.id === "ctx.storage");
  const pluginAssetFeature = capabilities.features.find((feature) => feature.id === "ui.image.pluginAsset");
  const focusFeature = capabilities.features.find((feature) => feature.id === "window.focus");
  assert.equal(fsFeature.status, "stable");
  assert.equal(storageFeature.status, "stable");
  assert.equal(storageFeature.asynchronous, true);
  assert.equal(pluginAssetFeature.status, "stable");
  assert.equal(pluginAssetFeature.integrationStatus, "verified-native-rendering");
  assert.equal(pluginAssetFeature.rendered, true);
  assert.equal(focusFeature.status, "unimplemented");
  assert.equal(focusFeature.injected, false);
  assert.equal(capabilities.packageLimits.maxPackageBytes, 32 * 1024 * 1024);
  assert.equal(capabilities.packageLimits.symlinksAllowed, false);
});

test("validate 接受设置唯一且资源存在的插件", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const output = execFileSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  const result = JSON.parse(output);
  assert.equal(result.ok, true);
  assert.equal(result.id, "com.example.demo");
  assert.deepEqual(result.errors, []);
});

test("validate 拒绝重复设置与缺失资源", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const manifestPath = path.join(fixture.plugin, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.settings.push({ key: "show", title: { en: "Again" }, default: false });
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(
    path.join(fixture.plugin, "main.js"),
    'globalThis.__switchlyPlugin = { render() { return "assets/missing.png"; } };\n',
  );

  const run = spawnSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  const result = JSON.parse(run.stdout);
  assert.equal(result.ok, false);
  assert(result.errors.some((error) => error.includes("设置 key 重复")));
  assert(result.errors.some((error) => error.includes("资源文件不存在")));
});

test("build 先验证再原样复制到 Plugins/id", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const outputRoot = path.join(fixture.root, "dist");
  const output = execFileSync(
    process.execPath,
    [cliPath, "build", fixture.plugin, "--out", outputRoot, "--json"],
    { encoding: "utf8" },
  );
  const result = JSON.parse(output);
  assert.equal(result.ok, true);
  assert.equal(result.compiled, false);
  assert.equal(result.artifact, path.join(outputRoot, "com.example.demo"));
  const copied = await readFile(path.join(result.artifact, "manifest.json"), "utf8");
  assert.equal(JSON.parse(copied).id, "com.example.demo");
});

test("validate 拒绝符号链接", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const { symlink } = await import("node:fs/promises");
  await symlink("assets/icon.png", path.join(fixture.plugin, "linked-icon.png"));
  const run = spawnSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  const result = JSON.parse(run.stdout);
  assert(result.errors.some((error) => error.includes("禁止符号链接")));
});

test("validate 拒绝未知权限与不配对的 fs.read", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const manifestPath = path.join(fixture.plugin, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.permissions = ["network", "fs.read"];
  await writeFile(manifestPath, JSON.stringify(manifest));

  const run = spawnSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  const result = JSON.parse(run.stdout);
  assert(result.errors.some((error) => error.includes("未知权限：network")));
  assert(result.errors.some((error) => error.includes("fs.read 权限与非空 fsRoots")));
});

test("create 从零创建可验证插件", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-plugin-create-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const plugin = path.join(root, "fresh-plugin");
  const output = execFileSync(process.execPath, [
    cliPath,
    "create",
    plugin,
    "--id",
    "com.example.fresh",
    "--name",
    "Fresh",
    "--match",
    "com.example.target",
    "--json",
  ], { encoding: "utf8" });
  const result = JSON.parse(output);
  assert.equal(result.ok, true);
  assert.equal(result.validation.ok, true);
  assert.equal(JSON.parse(await readFile(path.join(plugin, "manifest.json"), "utf8")).id, "com.example.fresh");
});

test("validate 只检查 fsRoots 声明而不访问真实目录", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const manifestPath = path.join(fixture.plugin, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.permissions = ["fs.read"];
  manifest.fsRoots = [{
    id: "missing",
    path: "~/switchly-plugin-cli-definitely-not-present",
    summary: { en: "Declaration only" },
  }];
  await writeFile(manifestPath, JSON.stringify(manifest));
  const output = execFileSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(JSON.parse(output).ok, true);
});

test("validate 对齐 manifest 名称、权限、effect 与选项唯一性门禁", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const manifestPath = path.join(fixture.plugin, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.name = { en: " " };
  manifest.permissions = ["weather.current", "weather.current"];
  manifest.refreshInterval = 86401;
  manifest.settings = [{
    key: "mode",
    type: "select",
    title: { en: "Mode" },
    default: "a",
    effect: "unknownEffect",
    options: [
      { value: "a", title: { en: "A" } },
      { value: "a", title: { en: "Again" } },
    ],
  }];
  await writeFile(manifestPath, JSON.stringify(manifest));
  const run = spawnSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  const result = JSON.parse(run.stdout);
  assert(result.errors.some((error) => error.includes("name")));
  assert(result.errors.some((error) => error.includes("permissions 包含重复项")));
  assert(result.errors.some((error) => error.includes("refreshInterval")));
  assert(result.errors.some((error) => error.includes("effect 必须是")));
  assert(result.errors.some((error) => error.includes("option value 重复")));
});

test("validate 不为动态资源前缀伪造静态路径", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  await writeFile(
    path.join(fixture.plugin, "main.js"),
    `const rarity = "common";
globalThis.__switchlyPlugin = { render() {
  return [{ slot: "center", node: { type: "image",
    source: { pluginAsset: "assets/" + rarity + ".png" } } }];
} };\n`,
  );
  const output = execFileSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(JSON.parse(output).ok, true);
});


test("build 拒绝覆盖自身源码且保留入口文件", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  const before = await readFile(path.join(fixture.plugin, "main.js"), "utf8");
  const result = spawnSync(process.execPath, [cliPath, "build", fixture.plugin, "--out", fixture.root], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.equal(await readFile(path.join(fixture.plugin, "main.js"), "utf8"), before);
});
