import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { cliContractHash } from "../src/compat.js";
import { parsePreviewArguments } from "../src/preview.js";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const cliPath = path.resolve(testDirectory, "../bin/switchly-plugin.js");

async function makeFixture(t, options = {}) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), "switchly-preview-cli-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  const plugin = path.join(root, "plugin");
  const scenario = path.join(root, "preview", "scenario.json");
  const app = path.join(root, "SwitchlyPluginPreview.app");
  const executable = path.join(app, "Contents", "MacOS", "SwitchlyPluginPreview");
  const argsLog = path.join(root, "args.json");
  await mkdir(plugin, { recursive: true });
  await mkdir(path.dirname(scenario), { recursive: true });
  await mkdir(path.dirname(executable), { recursive: true });
  await writeFile(scenario, JSON.stringify({ schemaVersion: 1, id: "demo" }));

  const stdout = options.stdout ?? JSON.stringify({
    schemaVersion: 1,
    status: "passed",
    scenarioID: "demo",
  });
  const stderr = options.stderr ?? "";
  const exitCode = options.exitCode ?? 0;
  // 假预览工具先回答 --version-json（与 CLI 兼容，可用 options.version 覆盖），再按选项模拟一次运行。
  const version = {
    tool: "switchly-plugin-preview", toolVersion: "0.1.0", protocolVersion: 1, scenarioSchemaVersion: 1,
    pluginAPIVersions: [1, 2], sdkContractHash: await cliContractHash(), rendererRevision: "sha256:test",
    architecture: "arm64", ...(options.version ?? {}),
  };
  await writeFile(executable, `#!/usr/bin/env node
const fs = require("node:fs");
if (process.argv[2] === "--version-json") {
  ${options.versionBehavior === "no-support" ? "process.exit(2);" : options.versionBehavior === "garbage" ? 'process.stdout.write("not json"); process.exit(0);' : `process.stdout.write(${JSON.stringify(JSON.stringify(version))}); process.exit(0);`}
}
fs.writeFileSync(${JSON.stringify(argsLog)}, JSON.stringify(process.argv.slice(2)));
process.stdout.write(${JSON.stringify(stdout)});
process.stderr.write(${JSON.stringify(stderr)});
process.exit(${exitCode});
`);
  await chmod(executable, 0o755);

  // 自定义假工具脚本复用这段，保持对 --version-json 的应答。
  const versionPreamble = `if (process.argv[2] === "--version-json") { process.stdout.write(${JSON.stringify(JSON.stringify(version))}); process.exit(0); }`;
  return {
    versionPreamble,
    root,
    plugin,
    scenario,
    app,
    executable,
    argsLog,
    out: path.join(root, "output"),
  };
}

function invoke(args) {
  return spawnSync(process.execPath, [cliPath, ...args], { encoding: "utf8" });
}

function parseSingleJSON(stdout) {
  const lines = stdout.trimEnd().split("\n");
  assert.equal(lines.length, 1, `stdout 应只有一个 JSON 行：${stdout}`);
  return JSON.parse(lines[0]);
}

test("dev/run 参数解析接受显式路径与等号形式", () => {
  const dev = parsePreviewArguments("dev", [
    "./plugin",
    "--preview-tool=./SwitchlyPluginPreview.app",
    "--scenario",
    "./scenario.json",
    "--json",
  ]);
  assert.deepEqual(dev, {
    command: "dev",
    json: true,
    previewTool: "./SwitchlyPluginPreview.app",
    scenario: "./scenario.json",
    overrides: null,
    out: null,
    plugin: "./plugin",
  });

  assert.throws(
    () => parsePreviewArguments("dev", ["./plugin", "--scenario", "./scenario.json", "--json"]),
    /缺少 --preview-tool/,
  );
  assert.throws(
    () => parsePreviewArguments("dev", [
      "./plugin", "--preview-tool", "./preview.app", "--scenario", "./scenario.json", "--out", "./out",
    ]),
    /dev 不接受 --out/,
  );
  assert.throws(
    () => parsePreviewArguments("run", [
      "./plugin", "--preview-tool", "./preview.app", "--scenario", "./scenario.json",
    ]),
    /run 缺少 --out/,
  );
});

test("后台截图参数仅允许 run 显式选择", () => {
  const base = ["./plugin", "--preview-tool", "./preview.app"];
  const run = parsePreviewArguments("run", [...base, "--out", "./out", "--background"]);
  assert.equal(run.background, true);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--background"]), /--background 仅供 run/);
  assert.throws(() => parsePreviewArguments("run", [...base, "--out", "./out", "--background", "--background"]), /--background 仅供 run/);
});

test("覆盖项解析：枚举、数字、key=value、可重复项与 fixture 形态", () => {
  const parsed = parsePreviewArguments("dev", [
    "./plugin",
    "--preview-tool", "./preview.app",
    "--locale", "zh-Hans",
    "--appearance=dark",
    "--glass",
    "--reduce-motion",
    "--width", "420",
    "--grants", "weather.current,fs.read",
    "--set", "show=false",
    "--set", "mode=compact",
    "--fixture", "media=./media.json",
    "--fixture", "weather=./weather.json",
    "--fixture", "fs=./fixture.json",
    "--target-bundle-id", "com.example.target",
    "--target-app-name", "Target",
  ]);
  assert.equal(parsed.scenario, null);
  assert.deepEqual(parsed.overrides, {
    locale: "zh-Hans",
    appearance: "dark",
    glass: true,
    reduceMotion: true,
    width: 420,
    grants: ["weather.current", "fs.read"],
    settings: [{ key: "show", value: "false" }, { key: "mode", value: "compact" }],
    fixtures: [
      { kind: "media", file: "./media.json" },
      { kind: "weather", file: "./weather.json" },
      { kind: "fs", file: "./fixture.json" },
    ],
    targetBundleID: "com.example.target",
    targetAppName: "Target",
  });

  const base = ["./plugin", "--preview-tool", "./preview.app"];
  assert.throws(() => parsePreviewArguments("dev", [...base, "--locale", "fr"]),
    /--locale 只接受 en 或 zh-Hans/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--appearance", "sepia"]),
    /--appearance 只接受 light 或 dark/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--width", "0"]),
    /--width 必须是大于 0 的点数/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--width", "abc"]),
    /--width 必须是大于 0 的点数/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--set", "missing-equals"]),
    /--set 需要 key=value/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--set", "=value"]),
    /--set 的 key 不能为空/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "video"]),
    /--fixture 需要 kind=<文件路径>/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "media"]),
    /--fixture media 需要显式文件路径/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "weather"]),
    /--fixture weather 需要显式文件路径/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "video=./video.json"]),
    /--fixture 只接受 media、weather、fs 或 activity/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "fs="]),
    /--fixture fs= 需要文件路径/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "media="]),
    /--fixture media= 需要文件路径/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--grants", "weather.current,"]),
    /--grants 的权限列表不能有空项/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--grants", "a,a"]),
    /--grants 的权限重复/);
});

test("覆盖项重复与布尔互斥被拒绝", () => {
  const base = ["./plugin", "--preview-tool", "./preview.app"];
  assert.throws(() => parsePreviewArguments("dev", [...base, "--glass", "--no-glass"]),
    /--glass 与 --no-glass 互斥/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--glass", "--glass"]),
    /--glass 与 --no-glass 互斥/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--reduce-motion", "--no-reduce-motion"]),
    /--reduce-motion 与 --no-reduce-motion 互斥/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--width", "300", "--width", "400"]),
    /--width 不能重复/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--set", "show=true", "--set", "show=false"]),
    /--set 的 key 重复：show/);
  assert.throws(() => parsePreviewArguments("dev", [...base, "--fixture", "media=./a.json", "--fixture", "media=./b.json"]),
    /--fixture media 不能重复/);
});

test("--scenario 与覆盖项互斥，错误信息指出使用条件且退出码为 2", () => {
  for (const override of [["--locale", "en"], ["--glass"], ["--width", "360"]]) {
    try {
      parsePreviewArguments("dev", [
        "./plugin", "--preview-tool", "./preview.app", "--scenario", "./scenario.json", ...override,
      ]);
      assert.fail("应拒绝同时使用 --scenario 与覆盖项");
    } catch (error) {
      assert.equal(error.exitCode, 2);
      assert.match(error.message, /覆盖项只在未提供 --scenario 时可用/);
    }
  }
});

test("inspect 参数解析只接受插件目录、--preview-tool 与 --json", () => {
  assert.deepEqual(
    parsePreviewArguments("inspect", ["./plugin", "--preview-tool", "./preview.app", "--json"]),
    {
      command: "inspect",
      json: true,
      previewTool: "./preview.app",
      scenario: null,
      overrides: null,
      out: null,
      plugin: "./plugin",
    },
  );
  const base = ["./plugin", "--preview-tool", "./preview.app"];
  assert.throws(() => parsePreviewArguments("inspect", [...base, "--scenario", "./s.json"]),
    /inspect 不接受 --scenario/);
  assert.throws(() => parsePreviewArguments("inspect", [...base, "--locale", "en"]),
    /inspect 不接受覆盖项/);
  assert.throws(() => parsePreviewArguments("inspect", [...base, "--out", "./out"]),
    /inspect 不接受 --out/);
});

test("未提供 --scenario 时透传覆盖项，三种 fixture 文件均解析为绝对路径", async (t) => {
  const fixture = await makeFixture(t);
  const mediaFixture = path.join(fixture.root, "media.json");
  const weatherFixture = path.join(fixture.root, "weather.json");
  const fsFixture = path.join(fixture.root, "fixture.json");
  await writeFile(mediaFixture, "{}");
  await writeFile(weatherFixture, "{}");
  await writeFile(fsFixture, "{}");
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool", fixture.app,
    "--locale", "zh-Hans",
    "--appearance", "dark",
    "--no-glass",
    "--reduce-motion",
    "--width", "420",
    "--grants", "none",
    "--set", "show=false",
    "--fixture", `media=${mediaFixture}`,
    "--fixture", `weather=${weatherFixture}`,
    "--fixture", `fs=${fsFixture}`,
    "--target-bundle-id", "com.example.target",
    "--target-app-name", "Target",
    "--json",
  ]);

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(await readFile(fixture.argsLog, "utf8")), [
    "dev",
    fixture.plugin,
    "--locale", "zh-Hans",
    "--appearance", "dark",
    "--no-glass",
    "--reduce-motion",
    "--width", "420",
    "--grants", "none",
    "--set", "show=false",
    "--fixture", `media=${mediaFixture}`,
    "--fixture", `weather=${weatherFixture}`,
    "--fixture", `fs=${fsFixture}`,
    "--target-bundle-id", "com.example.target",
    "--target-app-name", "Target",
    "--json",
  ]);
});

test("fixture 文件绝对路径在结果与诊断中脱敏", async (t) => {
  const fixture = await makeFixture(t);
  const mediaFixture = path.join(fixture.root, "media.json");
  await writeFile(mediaFixture, "{}");
  await writeFile(fixture.executable, `#!/usr/bin/env node
const fs = require("node:fs");
${fixture.versionPreamble}
fs.writeFileSync(${JSON.stringify(fixture.argsLog)}, JSON.stringify(process.argv.slice(2)));
process.stdout.write(${JSON.stringify(JSON.stringify({
    schemaVersion: 1,
    status: "passed",
    paths: [mediaFixture],
  }))});
process.stderr.write(${JSON.stringify(mediaFixture)});
`);
  await chmod(fixture.executable, 0o755);

  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool", fixture.app,
    "--fixture", `media=${mediaFixture}`,
    "--json",
  ]);

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(parseSingleJSON(result.stdout).paths, ["<fixture-path>"]);
  assert.match(result.stderr, /<fixture-path>/);
  assert(!result.stdout.includes(fixture.root), "stdout 不应包含 fixture 路径");
  assert(!result.stderr.includes(fixture.root), "stderr 不应包含 fixture 路径");
});

test("run 未提供 --scenario 时仍要求并透传 --out", async (t) => {
  const fixture = await makeFixture(t);
  const result = invoke([
    "run",
    fixture.plugin,
    "--preview-tool", fixture.app,
    "--glass",
    "--out", fixture.out,
    "--json",
  ]);

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(await readFile(fixture.argsLog, "utf8")), [
    "run",
    fixture.plugin,
    "--glass",
    "--out", fixture.out,
    "--json",
  ]);
});

test("--fixture 指向不存在的文件或目录时退出 2 且不启动预览工具", async (t) => {
  const fixture = await makeFixture(t);
  const missing = path.join(fixture.root, "missing.json");
  for (const kind of ["media", "weather", "fs"]) {
    const result = invoke([
      "dev",
      fixture.plugin,
      "--preview-tool", fixture.app,
      "--fixture", `${kind}=${missing}`,
      "--json",
    ]);

    assert.equal(result.status, 2);
    const output = parseSingleJSON(result.stdout);
    assert.equal(output.error.code, "invalid-arguments");
    assert.match(output.error.message, new RegExp(`--fixture ${kind} 的文件`));
  }

  const directory = path.join(fixture.root, "directory.json");
  await mkdir(directory, { recursive: true });
  const notFile = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool", fixture.app,
    "--fixture", `media=${directory}`,
    "--json",
  ]);
  assert.equal(notFile.status, 2);
  assert.match(parseSingleJSON(notFile.stdout).error.message, /--fixture media 的文件/);

  await assert.rejects(readFile(fixture.argsLog, "utf8"), { code: "ENOENT" });
});

test("dev 执行 App 内二进制并只转发一个已脱敏 JSON 结果", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: JSON.stringify({
      schemaVersion: 1,
      status: "passed",
      detail: "from-preview-tool",
    }),
    stderr: "diagnostic at",
  });
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 0, result.stderr);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "passed");
  assert.equal(output.detail, "from-preview-tool");
  assert.deepEqual(JSON.parse(await readFile(fixture.argsLog, "utf8")), [
    "dev",
    fixture.plugin,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);
  assert.match(result.stderr, /diagnostic at/);
});

test("run 传递 --out，诊断中的显式路径不会进入结果或日志", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: JSON.stringify({
      schemaVersion: 1,
      status: "passed",
      artifacts: { report: "report.json", screenshot: "preview.png" },
      diagnostic: "see",
    }),
    stderr: "",
  });
  const sensitiveStderr = [
    fixture.plugin,
    fixture.scenario,
    fixture.app,
    fixture.out,
    "data:image/png;base64,AAAA",
  ].join(" ");
  await writeFile(fixture.executable, `#!/usr/bin/env node
const fs = require("node:fs");
${fixture.versionPreamble}
fs.writeFileSync(${JSON.stringify(fixture.argsLog)}, JSON.stringify(process.argv.slice(2)));
process.stdout.write(${JSON.stringify(JSON.stringify({
    schemaVersion: 1,
    status: "passed",
    artifacts: { report: "report.json" },
    paths: [fixture.plugin, fixture.scenario, fixture.app, fixture.out],
  }))});
process.stderr.write(${JSON.stringify(sensitiveStderr)});
`);
  await chmod(fixture.executable, 0o755);

  const result = invoke([
    "run",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--out",
    fixture.out,
    "--json",
  ]);

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(await readFile(fixture.argsLog, "utf8")), [
    "run",
    fixture.plugin,
    "--scenario",
    fixture.scenario,
    "--out",
    fixture.out,
    "--json",
  ]);
  assert(!result.stdout.includes(fixture.root), "stdout 不应包含显式输入路径");
  assert(!result.stderr.includes(fixture.root), "stderr 不应包含显式输入路径");
  assert.match(result.stderr, /<plugin-path>/);
  assert.match(result.stderr, /<scenario-path>/);
  assert.match(result.stderr, /<preview-tool>/);
  assert.match(result.stderr, /<output-path>/);
  assert.match(result.stderr, /<embedded-image-data>/);
  parseSingleJSON(result.stdout);
});

test("找不到预览工具返回独立的环境错误且不泄露路径", async (t) => {
  const fixture = await makeFixture(t);
  const missingApp = path.join(fixture.root, "missing.app");
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    missingApp,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 4);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "environment-error");
  assert.equal(output.error.code, "preview-tool-not-found");
  assert(!result.stdout.includes(fixture.root));
  assert(!result.stderr.includes(fixture.root));
});

test("run 拒绝覆盖非空输出且不会启动预览工具", async (t) => {
  const fixture = await makeFixture(t);
  await mkdir(fixture.out, { recursive: true });
  const existing = path.join(fixture.out, "report.json");
  await writeFile(existing, "existing");
  const result = invoke([
    "run",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--out",
    fixture.out,
    "--json",
  ]);

  assert.equal(result.status, 2);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "failed");
  assert.equal(output.error.code, "invalid-arguments");
  assert.equal(await readFile(existing, "utf8"), "existing");
  await assert.rejects(readFile(fixture.argsLog, "utf8"), { code: "ENOENT" });
});

test("预览进程非零退出返回 failed，JSON stdout 仍只有一个对象", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: "",
    stderr: "process failure",
    exitCode: 7,
  });
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 1);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "failed");
  assert.equal(output.error.code, "preview-process-failed");
  assert.match(result.stderr, /process failure/);
});

// Linux 的 execvp 会把无 shebang 的文本回退给 /bin/sh 执行，无法稳定复现“无法执行”；预览工具只运行在 macOS。
test("预览二进制无法执行时返回环境错误且 stdout 仍只有一个对象", { skip: process.platform !== "darwin" }, async (t) => {
  const fixture = await makeFixture(t);
  await writeFile(fixture.executable, "not an executable format");
  await chmod(fixture.executable, 0o755);
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 4);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "environment-error");
  assert.equal(output.error.code, "preview-process-launch-failed");
});

test("预览工具报告 GUI 环境错误时保留环境错误状态和退出码", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: JSON.stringify({
      schemaVersion: 1,
      status: "environment-error",
      error: { code: "gui-unavailable" },
    }),
    exitCode: 0,
  });
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 4);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "environment-error");
  assert.equal(output.error.code, "gui-unavailable");
});

test("预览工具输出多个 JSON 值时 CLI 只输出一个环境错误对象", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: '{"schemaVersion":1,"status":"passed"}\n{"schemaVersion":1,"status":"passed"}\n',
  });
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 4);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "environment-error");
  assert.equal(output.error.code, "invalid-tool-output");
});

test("unsupported 结果保留对象并使用独立非零退出码", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: JSON.stringify({
      schemaVersion: 1,
      status: "unsupported",
      reason: "steps are not available in P0",
    }),
    exitCode: 0,
  });
  const result = invoke([
    "dev",
    fixture.plugin,
    "--preview-tool",
    fixture.app,
    "--scenario",
    fixture.scenario,
    "--json",
  ]);

  assert.equal(result.status, 3);
  assert.equal(parseSingleJSON(result.stdout).status, "unsupported");
});

test("只向 CLI 发送 SIGTERM 时转发给预览进程，不留下孤儿", async (t) => {
  const fixture = await makeFixture(t);
  const marker = path.join(fixture.root, "child-got-signal");
  const ready = path.join(fixture.root, "child-ready");
  // 假预览进程：就绪后挂起，收到 SIGTERM 才写标记并以 143 退出。
  await writeFile(fixture.executable, `#!/usr/bin/env node
const fs = require("node:fs");
${fixture.versionPreamble}
process.on("SIGTERM", () => { fs.writeFileSync(${JSON.stringify(marker)}, String(process.pid)); process.exit(143); });
fs.writeFileSync(${JSON.stringify(ready)}, String(process.pid));
setInterval(() => {}, 1000);
`);
  const cli = spawn(process.execPath, [cliPath, "dev", fixture.plugin, "--preview-tool", fixture.app, "--scenario", fixture.scenario],
    { stdio: "ignore" });
  const exited = new Promise((resolve) => cli.on("exit", (code, signal) => resolve({ code, signal })));
  let childPID = null;
  for (let attempt = 0; attempt < 100 && childPID === null; attempt += 1) {
    try { childPID = Number(await readFile(ready, "utf8")); } catch { await new Promise((r) => setTimeout(r, 50)); }
  }
  assert.ok(childPID, "假预览进程应已启动");
  cli.kill("SIGTERM");
  const result = await Promise.race([exited, new Promise((resolve) => setTimeout(() => resolve("timeout"), 8000))]);
  if (result === "timeout") { cli.kill("SIGKILL"); try { process.kill(childPID, "SIGKILL"); } catch { /* 已退出 */ } }
  assert.notEqual(result, "timeout", "CLI 应在子进程退出后结束，而不是挂起");
  assert.equal(Number(await readFile(marker, "utf8")), childPID, "子进程必须收到被转发的 SIGTERM");
  assert.throws(() => process.kill(childPID, 0), "子进程不应存活");
});

function runDev(fixture, extra = []) {
  return invoke(["dev", fixture.plugin, "--preview-tool", fixture.app, "--scenario", fixture.scenario, "--json", ...extra]);
}

test("兼容握手：契约哈希、协议、场景版本与工具主版本不一致时在启动预览前拒绝，并列出可操作的诊断", async (t) => {
  const fixture = await makeFixture(t, {
    version: { sdkContractHash: "sha256:stale", protocolVersion: 2, scenarioSchemaVersion: 3, toolVersion: "1.4.0" },
  });
  const result = runDev(fixture);
  assert.equal(result.status, 4);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "environment-error");
  assert.equal(output.error.code, "incompatible-preview-tool");
  assert.deepEqual(output.error.details.mismatches.map((item) => item.field).sort(),
    ["protocolVersion", "scenarioSchemaVersion", "sdkContractHash", "toolVersion"]);
  assert.match(output.error.message, /同一工具包/, "诊断必须告诉作者怎么修");
  await assert.rejects(readFile(fixture.argsLog), "不兼容时不得启动预览");
});

test("兼容握手：插件 apiVersion 超出工具支持范围返回 unsupported（退出码 3）", async (t) => {
  const fixture = await makeFixture(t, { version: { pluginAPIVersions: [1] } });
  await writeFile(path.join(fixture.plugin, "manifest.json"), JSON.stringify({ apiVersion: 2 }));
  const result = runDev(fixture);
  assert.equal(result.status, 3);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "unsupported");
  assert.equal(output.error.code, "plugin-api-unsupported");
  assert.deepEqual(output.error.details, { pluginAPIVersion: 2, supported: [1] });
});

test("兼容握手：工具不支持 --version-json 或输出无效时拒绝，而不是盲目运行", async (t) => {
  for (const versionBehavior of ["no-support", "garbage"]) {
    const fixture = await makeFixture(t, { versionBehavior });
    const result = runDev(fixture);
    assert.equal(result.status, 4, versionBehavior);
    assert.equal(parseSingleJSON(result.stdout).error.code, "incompatible-preview-tool", versionBehavior);
    await assert.rejects(readFile(fixture.argsLog), `${versionBehavior} 时不得启动预览`);
  }
});

test("兼容握手：兼容的工具正常运行，manifest 不可读时不阻断（由预览工具与 validate 报告）", async (t) => {
  const fixture = await makeFixture(t);
  await writeFile(path.join(fixture.plugin, "manifest.json"), "{ not json");
  const result = runDev(fixture);
  assert.equal(result.status, 0);
  assert.equal(parseSingleJSON(result.stdout).status, "passed");
});

function inspectPayload() {
  return {
    schemaVersion: 1,
    plugin: {
      id: "com.example.demo",
      name: { en: "Demo", "zh-Hans": "示例" },
      version: "1",
      apiVersion: 2,
      matches: ["com.example.app"],
      permissions: ["weather.current"],
    },
    defaultScenario: {
      schemaVersion: 1,
      id: "default",
      environment: {
        locale: "en", appearance: "light", glass: false, reduceMotion: true, contentWidthPoints: 360,
      },
      target: { bundleID: "com.example.app", appName: "Com.example.app" },
      grants: ["weather.current"],
      clock: { startEpochMs: 1700000000000, seed: 1 },
    },
    settings: [
      { key: "show", kind: "toggle", default: true },
      { key: "mode", kind: "select", default: "a", options: [{ value: "a" }, { value: "b" }] },
      { key: "level", kind: "number", default: 3, min: 0, max: 10, step: 1 },
    ],
    fixtures: [
      { kind: "media", needed: true, reason: "插件读取 media fixture" },
      { kind: "weather", needed: false },
    ],
  };
}

function runInspect(fixture, extra = []) {
  return invoke(["inspect", fixture.plugin, "--preview-tool", fixture.app, ...extra]);
}

test("inspect --json 原样输出预览工具的单个 JSON 对象", async (t) => {
  const payload = inspectPayload();
  const fixture = await makeFixture(t, { stdout: JSON.stringify(payload) });
  const result = runInspect(fixture, ["--json"]);

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(parseSingleJSON(result.stdout), payload);
  assert.deepEqual(JSON.parse(await readFile(fixture.argsLog, "utf8")), ["inspect", fixture.plugin]);
});

test("inspect 人类可读摘要覆盖插件、权限、设置、fixture、默认场景与下一步", async (t) => {
  const fixture = await makeFixture(t, { stdout: JSON.stringify(inspectPayload()) });
  const result = runInspect(fixture);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /插件：com\.example\.demo（示例） 版本 1（API 2）/);
  assert.match(result.stdout, /匹配应用：com\.example\.app/);
  assert.match(result.stdout, /权限：weather\.current/);
  assert.match(result.stdout, /show（toggle，默认 true）/);
  assert.match(result.stdout, /mode（select，默认 a；选项 a、b）/);
  assert.match(result.stdout, /level（number，默认 3；范围 0–10；步长 1）/);
  assert.match(result.stdout, /media（需用 --fixture media=<文件> 提供）：插件读取 media fixture/);
  assert.doesNotMatch(result.stdout, /weather（需用/, "needed=false 的 fixture 不应列入所需项");
  assert.match(result.stdout, /id=default，语言=en，外观=light，玻璃=关，减少动态效果=开，宽度=360pt/);
  assert.match(result.stdout, /switchly-plugin run <插件目录> --preview-tool <App> --out <输出目录>/);
});

test("inspect 沿用版本握手：不兼容时不调用检查", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: JSON.stringify(inspectPayload()),
    version: { sdkContractHash: "sha256:stale" },
  });
  const result = runInspect(fixture, ["--json"]);

  assert.equal(result.status, 4);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.error.code, "incompatible-preview-tool");
  await assert.rejects(readFile(fixture.argsLog, "utf8"), { code: "ENOENT" });
});

test("inspect 的失败结果保留预览工具的状态与退出码映射", async (t) => {
  const fixture = await makeFixture(t, {
    stdout: JSON.stringify({
      schemaVersion: 1,
      status: "unsupported",
      error: { code: "plugin-api-unsupported", message: "插件 API 版本不受支持" },
    }),
  });
  const result = runInspect(fixture, ["--json"]);

  assert.equal(result.status, 3);
  const output = parseSingleJSON(result.stdout);
  assert.equal(output.status, "unsupported");
  assert.equal(output.error.code, "plugin-api-unsupported");
});


test("活动夹具覆盖项保留种类与路径", () => {
  const parsed = parsePreviewArguments("dev", ["./plugin", "--preview-tool", "./preview.app", "--fixture", "activity=./activity.json"]);
  assert.deepEqual(parsed.overrides.fixtures, [{ kind: "activity", file: "./activity.json" }]);
});
