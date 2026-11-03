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
