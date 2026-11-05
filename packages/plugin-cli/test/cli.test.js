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
import { validateManifest } from "../src/validate.js";

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

function manifestWithSettings(settings) {
  return {
    id: "com.example.settings",
    name: { en: "Settings" },
    version: "1",
    apiVersion: 2,
    matches: ["com.example.app"],
    permissions: [],
    entry: "main.js",
    settings,
  };
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

test("公共 manifest 校验接受 toggle/select/number 并拒绝设置漂移", () => {
  const valid = validateManifest(manifestWithSettings([
    { key: "enabled", title: { en: "Enabled" }, default: true },
    {
      key: "mode",
      type: "select",
      title: { en: "Mode" },
      default: "compact",
      options: [
        { value: "compact", title: { en: "Compact" } },
        { value: "detailed", title: { en: "Detailed" } },
      ],
    },
    {
      key: "temperature",
      type: "number",
      title: { en: "Temperature" },
      default: 20,
      min: -40,
      max: 50,
      step: 1,
    },
  ]));
  assert.equal(valid.ok, true);
  assert.deepEqual(valid.errors, []);

  const invalidCases = [
    [
      { key: "text", type: "string", title: { en: "Text" }, default: "hello" },
      "type 未知",
    ],
    [
      { key: "enabled", title: { en: "Enabled" }, default: "true" },
      "toggle 必须是 boolean",
    ],
    [
      { key: "mode", type: "select", title: { en: "Mode" }, default: "a", options: [] },
      "options 对 select 必须是非空数组",
    ],
    [
      {
        key: "mode",
        type: "select",
        title: { en: "Mode" },
        default: "missing",
        options: [{ value: "a", title: { en: "A" } }],
      },
      "default 不在 options 中",
    ],
    [
      { key: "level", type: "number", title: { en: "Level" }, default: "1" },
      "number 必须是有限数字",
    ],
    [
      { key: "level", type: "number", title: { en: "Level" }, default: 1, step: 0 },
      "step 必须大于 0",
    ],
    [
      {
        key: "level",
        type: "number",
        title: { en: "Level" },
        default: 20,
        min: 0,
        max: 10,
      },
      "default 大于 max",
    ],
  ];

  for (const [setting, expected] of invalidCases) {
    const result = validateManifest(manifestWithSettings([setting]));
    assert.equal(result.ok, false, expected);
    assert(result.errors.some((error) => error.includes(expected)), `${expected}: ${result.errors.join("; ")}`);
  }
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

test("validate 拒绝非法 manifest JSON", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  await writeFile(path.join(fixture.plugin, "manifest.json"), "{");
  const run = spawnSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  const result = JSON.parse(run.stdout);
  assert(result.errors.some((error) => error.includes("manifest.json 无法读取或不是合法 JSON")));
});

test("validate 拒绝超过入口体积预算的脚本", async (t) => {
  const fixture = await makePlugin();
  t.after(() => rm(fixture.root, { recursive: true, force: true }));
  await writeFile(path.join(fixture.plugin, "main.js"), Buffer.alloc(2 * 1024 * 1024 + 1, "a"));
  const run = spawnSync(process.execPath, [cliPath, "validate", fixture.plugin, "--json"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  const result = JSON.parse(run.stdout);
  assert(result.errors.some((error) => error.includes("entry 超过 2 MiB")));
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
  const entry = await readFile(path.join(plugin, "main.js"), "utf8");
  assert.match(entry, /slot: "center"/, "默认模板必须渲染到 center，run 才能捕获");
  assert.match(entry, /\/\/ render 返回要展示的节点数组/);
  assert.match(entry, /\/\/ 可选：onAction/);
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
