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
  await writeFile(executable, `#!/usr/bin/env node
const fs = require("node:fs");
fs.writeFileSync(${JSON.stringify(argsLog)}, JSON.stringify(process.argv.slice(2)));
process.stdout.write(${JSON.stringify(stdout)});
process.stderr.write(${JSON.stringify(stderr)});
process.exit(${exitCode});
`);
  await chmod(executable, 0o755);

  return {
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

test("预览二进制无法执行时返回环境错误且 stdout 仍只有一个对象", async (t) => {
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
