import { spawn } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import {
  access,
  lstat,
  readdir,
  readFile,
  realpath,
  stat,
} from "node:fs/promises";
import path from "node:path";
import { cliContractHash, findMismatches, queryToolVersion } from "./compat.js";

const EXIT = Object.freeze({
  passed: 0,
  failed: 1,
  invalidArguments: 2,
  unsupported: 3,
  environmentError: 4,
});

const PREVIEW_EXECUTABLE = path.join("Contents", "MacOS", "SwitchlyPluginPreview");
const MAX_JSON_OUTPUT_BYTES = 8 * 1024 * 1024;
const MAX_DIAGNOSTIC_BUFFER_BYTES = 64 * 1024;
const FORWARDED_SIGNAL_GRACE_MS = 10_000;
const RESULT_STATUSES = new Set(["passed", "failed", "unsupported", "environment-error"]);

class PreviewCliError extends Error {
  constructor(code, message, status = "failed", exitCode = EXIT.failed, details = undefined) {
    super(message);
    this.code = code;
    this.status = status;
    this.exitCode = exitCode;
    this.details = details;
  }
}

function argumentError(message) {
  return new PreviewCliError("invalid-arguments", message, "failed", EXIT.invalidArguments);
}

function environmentError(code, message) {
  return new PreviewCliError(code, message, "environment-error", EXIT.environmentError);
}

function optionValue(args, index, name) {
  const arg = args[index];
  if (arg === name) {
    const value = args[index + 1];
    if (!value || value.startsWith("--")) throw argumentError(`${name} 缺少值；请在 ${name} 后写出取值。`);
    return { value, consumed: 2 };
  }
  const prefix = `${name}=`;
  if (arg.startsWith(prefix)) {
    const value = arg.slice(prefix.length);
    if (!value) throw argumentError(`${name} 缺少值；请使用 ${name}=<取值> 或 ${name} <取值>。`);
    return { value, consumed: 1 };
  }
  return null;
}

function enumValue(name, value, allowed, example) {
  if (!allowed.includes(value)) {
    throw argumentError(`${name} 只接受 ${allowed.join(" 或 ")}；例如 ${example}。`);
  }
  return value;
}

function parsePositiveNumber(name, value, example) {
  if (!/^(?:\d+(?:\.\d+)?|\.\d+)$/.test(value) || Number(value) <= 0) {
    throw argumentError(`${name} 必须是大于 0 的点数；例如 ${example}。`);
  }
  return Number(value);
}

function parseGrants(value) {
  if (value === "none") return [];
  const items = value.split(",").map((item) => item.trim());
  if (items.some((item) => item === "")) {
    throw argumentError('--grants 的权限列表不能有空项；例如 --grants none 或 --grants weather.current,fs.read。');
  }
  const duplicates = items.filter((item, index) => items.indexOf(item) !== index);
  if (duplicates.length > 0) {
    throw argumentError(`--grants 的权限重复：${[...new Set(duplicates)].join("、")}；请每个权限只列一次。`);
  }
  return items;
}

function parseSetting(value) {
  const separator = value.indexOf("=");
  if (separator === -1) {
    throw argumentError('--set 需要 key=value；例如 --set show=false 或 --set mode=compact。');
  }
  const key = value.slice(0, separator);
  if (key.trim() === "") {
    throw argumentError('--set 的 key 不能为空；例如 --set show=false。');
  }
  return { key, value: value.slice(separator + 1) };
}

const FIXTURE_KINDS = Object.freeze(["media", "weather", "fs"]);

function parseFixture(value) {
  const separator = value.indexOf("=");
  if (separator === -1) {
    if (FIXTURE_KINDS.includes(value)) {
      throw argumentError(`--fixture ${value} 需要显式文件路径；请使用 --fixture ${value}=<文件路径>。`);
    }
    throw argumentError('--fixture 需要 kind=<文件路径>，media、weather、fs 三种都必须提供文件；例如 --fixture media=./media.json。');
  }
  const kind = value.slice(0, separator);
  if (!FIXTURE_KINDS.includes(kind)) {
    throw argumentError(`--fixture 只接受 media、weather 或 fs；收到 "${kind}"，例如 --fixture media=./media.json。`);
  }
  const file = value.slice(separator + 1);
  if (!file) {
    throw argumentError(`--fixture ${kind}= 需要文件路径；例如 --fixture ${kind}=./fixture.json。`);
  }
  return { kind, file };
}

/**
 * Parse only the public CLI surface. Filesystem and preview-tool checks happen
 * after all arguments have been validated so usage errors never launch a tool.
 */
export function parsePreviewArguments(command, args) {
  if (!["dev", "run", "inspect"].includes(command)) {
    throw argumentError("预览命令必须是 dev、run 或 inspect");
  }

  const options = {
    command,
    json: false,
    previewTool: null,
    scenario: null,
    overrides: null,
    out: null,
    plugin: null,
  };
  const overrides = {
    locale: null,
    appearance: null,
    glass: null,
    reduceMotion: null,
    width: null,
    grants: null,
    settings: [],
    fixtures: [],
    targetBundleID: null,
    targetAppName: null,
  };
  const seen = new Set();
  const fixtureKinds = new Set();
  const settingKeys = new Set();
  const positional = [];

  const once = (name, label) => {
    if (seen.has(name)) throw argumentError(`${label} 不能重复；请只提供一次。`);
    seen.add(name);
  };

  for (let index = 0; index < args.length;) {
    const arg = args[index];
    if (arg === "--json") {
      if (options.json) throw argumentError("--json 不能重复；请只提供一次。");
      options.json = true;
      index += 1;
      continue;
    }

    if (arg === "--glass" || arg === "--no-glass") {
      if (seen.has("glass")) {
        throw argumentError("--glass 与 --no-glass 互斥且只能使用一次；请只保留其中一个。");
      }
      seen.add("glass");
      overrides.glass = arg === "--glass";
      index += 1;
      continue;
    }

    if (arg === "--reduce-motion" || arg === "--no-reduce-motion") {
      if (seen.has("reduceMotion")) {
        throw argumentError("--reduce-motion 与 --no-reduce-motion 互斥且只能使用一次；请只保留其中一个。");
      }
      seen.add("reduceMotion");
      overrides.reduceMotion = arg === "--reduce-motion";
      index += 1;
      continue;
    }

    let parsed = optionValue(args, index, "--preview-tool");
    if (parsed) {
      if (options.previewTool !== null) throw argumentError("--preview-tool 不能重复；请只提供一次。");
      options.previewTool = parsed.value;
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--scenario");
    if (parsed) {
      if (options.scenario !== null) throw argumentError("--scenario 不能重复；请只提供一次。");
      options.scenario = parsed.value;
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--out");
    if (parsed) {
      if (command !== "run") {
        throw argumentError(`${command} 不接受 --out；${command === "inspect" ? "检查结果直接输出到 stdout。" : "只有 run 才会写入输出目录。"}`);
      }
      if (options.out !== null) throw argumentError("--out 不能重复；请只提供一次。");
      options.out = parsed.value;
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--locale");
    if (parsed) {
      once("locale", "--locale");
      overrides.locale = enumValue("--locale", parsed.value, ["en", "zh-Hans"], "--locale zh-Hans");
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--appearance");
    if (parsed) {
      once("appearance", "--appearance");
      overrides.appearance = enumValue("--appearance", parsed.value, ["light", "dark"], "--appearance dark");
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--width");
    if (parsed) {
      once("width", "--width");
      overrides.width = parsePositiveNumber("--width", parsed.value, "--width 360");
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--grants");
    if (parsed) {
      once("grants", "--grants");
      overrides.grants = parseGrants(parsed.value);
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--set");
    if (parsed) {
      const setting = parseSetting(parsed.value);
      if (settingKeys.has(setting.key)) {
        throw argumentError(`--set 的 key 重复：${setting.key}；每个设置项只能覆盖一次。`);
      }
      settingKeys.add(setting.key);
      overrides.settings.push(setting);
      seen.add("settings");
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--fixture");
    if (parsed) {
      const fixture = parseFixture(parsed.value);
      if (fixtureKinds.has(fixture.kind)) {
        throw argumentError(`--fixture ${fixture.kind} 不能重复；每种 fixture 最多提供一次。`);
      }
      fixtureKinds.add(fixture.kind);
      overrides.fixtures.push(fixture);
      seen.add("fixtures");
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--target-bundle-id");
    if (parsed) {
      once("targetBundleID", "--target-bundle-id");
      overrides.targetBundleID = parsed.value;
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--target-app-name");
    if (parsed) {
      once("targetAppName", "--target-app-name");
      overrides.targetAppName = parsed.value;
      index += parsed.consumed;
      continue;
    }

    if (arg.startsWith("--")) {
      throw argumentError(`包含未知参数：${arg}；请运行 switchly-plugin --help 查看支持的参数。`);
    }
    positional.push(arg);
    index += 1;
  }

  if (positional.length !== 1) throw argumentError(`${command} 需要一个插件目录；请提供一个目录参数。`);
  options.plugin = positional[0];
  if (!options.previewTool) {
    throw argumentError("缺少 --preview-tool；请用 --preview-tool 指向 SwitchlyPluginPreview.app。");
  }

  if (command === "inspect") {
    if (options.scenario !== null) {
      throw argumentError("inspect 不接受 --scenario；inspect 只读取插件并输出默认场景，不运行预览。");
    }
    if (seen.size > 0) {
      throw argumentError("inspect 不接受覆盖项；覆盖项只用于 dev/run，请移除后重试。");
    }
  } else {
    if (options.scenario !== null && seen.size > 0) {
      throw argumentError("--locale、--appearance 等覆盖项只在未提供 --scenario 时可用；请移除 --scenario，或删除覆盖项改用场景文件。");
    }
    if (seen.size > 0) options.overrides = overrides;
  }

  if (command === "run" && !options.out) {
    throw argumentError("run 缺少 --out；请用 --out 指定一个空的输出目录。");
  }
  return options;
}

async function requireDirectory(directory, message) {
  try {
    const info = await stat(directory);
    if (!info.isDirectory()) throw new Error("not a directory");
  } catch {
    throw argumentError(`${message}不存在或不是目录`);
  }
}

async function requireFile(file, message) {
  try {
    const info = await stat(file);
    if (!info.isFile()) throw new Error("not a file");
  } catch {
    throw argumentError(`${message}不存在或不是普通文件`);
  }
}

function isWithin(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

async function inspectOutputDirectory(outputDirectory) {
  let info;
  try {
    info = await lstat(outputDirectory);
  } catch (error) {
    if (error.code !== "ENOENT") throw argumentError("输出目录无法检查");
  }

  if (info) {
    if (info.isSymbolicLink() || !info.isDirectory()) {
      throw argumentError("--out 必须是普通目录且不能是符号链接");
    }
    if ((await readdir(outputDirectory)).length > 0) {
      throw argumentError("--out 目录非空，拒绝覆盖现有输出");
    }
    return await realpath(outputDirectory);
  }

  const parent = path.dirname(outputDirectory);
  try {
    const parentInfo = await stat(parent);
    if (!parentInfo.isDirectory()) throw new Error("not a directory");
    return path.join(await realpath(parent), path.basename(outputDirectory));
  } catch {
    throw argumentError("--out 的父目录不存在或不是目录");
  }
}

async function resolvePreviewTool(input) {
  const requestedApp = path.resolve(input);
  if (path.extname(requestedApp) !== ".app") {
    throw argumentError("--preview-tool 必须指向 .app");
  }
  let appDirectory;
  try {
    const info = await stat(requestedApp);
    if (!info.isDirectory()) throw new Error("not a directory");
    appDirectory = await realpath(requestedApp);
  } catch {
    throw environmentError("preview-tool-not-found", "找不到预览工具 App");
  }

  const executable = path.join(appDirectory, PREVIEW_EXECUTABLE);
  try {
    const info = await stat(executable);
    if (!info.isFile()) throw new Error("not a file");
    await access(executable, fsConstants.X_OK);
  } catch {
    throw environmentError("preview-executable-not-found", "预览工具缺少可执行的 SwitchlyPluginPreview");
  }
  return { appDirectory, executable };
}

async function resolvePreviewRequest(options) {
  const plugin = path.resolve(options.plugin);
  await requireDirectory(plugin, "插件目录");
  let scenario = null;
  if (options.scenario !== null) {
    scenario = path.resolve(options.scenario);
    await requireFile(scenario, "场景文件");
  }
  const pluginRealPath = await realpath(plugin);
  const scenarioRealPath = scenario ? await realpath(scenario) : null;
  const previewTool = await resolvePreviewTool(options.previewTool);
  let overrides = null;

  if (options.overrides) {
    overrides = { ...options.overrides, fixtures: [] };
    for (const fixture of options.overrides.fixtures) {
      const file = path.resolve(fixture.file);
      await requireFile(file, `--fixture ${fixture.kind} 的文件（${fixture.file}）`);
      overrides.fixtures.push({ kind: fixture.kind, file });
    }
  }

  let out = null;
  if (options.command === "run") {
    out = await inspectOutputDirectory(path.resolve(options.out));
    if (isWithin(pluginRealPath, out) || isWithin(out, pluginRealPath)) {
      throw argumentError("--out 不能与插件源码目录重叠；请换一个独立的输出目录。");
    }
  }

  return {
    command: options.command,
    json: options.json,
    plugin: pluginRealPath,
    scenario: scenarioRealPath,
    overrides,
    out,
    previewTool: previewTool.appDirectory,
    executable: previewTool.executable,
  };
}

function appendOverrides(args, overrides) {
  if (overrides.locale !== null) args.push("--locale", overrides.locale);
  if (overrides.appearance !== null) args.push("--appearance", overrides.appearance);
  if (overrides.glass !== null) args.push(overrides.glass ? "--glass" : "--no-glass");
  if (overrides.reduceMotion !== null) {
    args.push(overrides.reduceMotion ? "--reduce-motion" : "--no-reduce-motion");
  }
  if (overrides.width !== null) args.push("--width", String(overrides.width));
  if (overrides.grants !== null) {
    args.push("--grants", overrides.grants.length > 0 ? overrides.grants.join(",") : "none");
  }
  for (const setting of overrides.settings) args.push("--set", `${setting.key}=${setting.value}`);
  for (const fixture of overrides.fixtures) {
    args.push("--fixture", `${fixture.kind}=${fixture.file}`);
  }
  if (overrides.targetBundleID !== null) args.push("--target-bundle-id", overrides.targetBundleID);
  if (overrides.targetAppName !== null) args.push("--target-app-name", overrides.targetAppName);
}

function appArguments(request) {
  const args = [request.command, request.plugin];
  if (request.command === "inspect") return args;
  if (request.scenario) args.push("--scenario", request.scenario);
  else if (request.overrides) appendOverrides(args, request.overrides);
  if (request.command === "run") args.push("--out", request.out);
  if (request.json) args.push("--json");
  return args;
}

function createSanitizer(request) {
  const replacements = [
    [request.executable, "<preview-executable>"],
    [request.previewTool, "<preview-tool>"],
    [request.plugin, "<plugin-path>"],
  ];
  if (request.scenario) replacements.push([request.scenario, "<scenario-path>"]);
  if (request.out) replacements.push([request.out, "<output-path>"]);
  for (const fixture of request.overrides?.fixtures ?? []) {
    replacements.push([fixture.file, "<fixture-path>"]);
  }
  replacements.sort((left, right) => right[0].length - left[0].length);

  return (value) => {
    let sanitized = value;
    for (const [sensitive, label] of replacements) {
      sanitized = sanitized.split(sensitive).join(label);
    }
    return sanitized.replace(/data:image\/[^;,\s"']+;base64,[^\s"']+/g, "<embedded-image-data>");
  };
}

function sanitizeJSON(value, sanitize) {
  if (typeof value === "string") return sanitize(value);
  if (Array.isArray(value)) return value.map((item) => sanitizeJSON(item, sanitize));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [sanitize(key), sanitizeJSON(item, sanitize)]),
    );
  }
  return value;
}

function writeDiagnostic(stream, message) {
  stream.write(message.endsWith("\n") ? message : `${message}\n`);
}

function createLineWriter(stream, sanitize) {
  let pending = "";
  return {
    push(chunk) {
      pending += chunk;
      if (pending.length > MAX_DIAGNOSTIC_BUFFER_BYTES) {
        stream.write(sanitize(pending));
        pending = "";
        return;
      }
      let newline = pending.indexOf("\n");
      while (newline !== -1) {
        stream.write(sanitize(pending.slice(0, newline + 1)));
        pending = pending.slice(newline + 1);
        newline = pending.indexOf("\n");
      }
    },
    finish() {
      if (pending) stream.write(sanitize(pending));
      pending = "";
    },
  };
}

function failureResult(command, error) {
  return {
    schemaVersion: 1,
    command,
    status: error.status,
    error: {
      code: error.code,
      message: error.message,
      ...(error.details ? { details: error.details } : {}),
    },
  };
}

const COMPAT_HINT = "请使用同一工具包中的 switchly-plugin CLI 与 SwitchlyPluginPreview.app（版本、协议与契约必须配套）。";

/**
 * 启动预览前核对工具与 CLI、插件的兼容性。任何一项无法确认或不一致都在此处以可操作的诊断拒绝。
 */
async function checkToolCompatibility(request, io) {
  const result = await queryToolVersion(request.executable, io.spawn);
  if (result.failure === "launch-failed") {
    throw environmentError("preview-process-launch-failed", "预览工具无法启动");
  }
  if (result.failure) {
    const reasons = {
      unresponsive: "预览工具没有在时限内报告版本",
      "no-version-support": "预览工具不支持 --version-json（版本过旧或不是预览工具）",
      "invalid-output": "预览工具报告的版本信息无效",
    };
    throw environmentError("incompatible-preview-tool", `${reasons[result.failure]}。${COMPAT_HINT}`);
  }
  let expectedHash;
  try {
    expectedHash = await cliContractHash();
  } catch {
    throw environmentError("cli-contract-missing", "CLI 缺少随包契约文件，无法核对兼容性；请重新安装工具包。");
  }
  const mismatches = findMismatches(result.tool, expectedHash);
  if (mismatches.length > 0) {
    const summary = mismatches.map((item) => `${item.field}（CLI 要求 ${item.expected}，工具为 ${item.actual}）`).join("；");
    throw new PreviewCliError("incompatible-preview-tool", `预览工具与 CLI 不兼容：${summary}。${COMPAT_HINT}`,
      "environment-error", EXIT.environmentError, { mismatches });
  }
  const pluginAPIVersion = await readPluginAPIVersion(request.plugin);
  if (pluginAPIVersion !== null && !result.tool.pluginAPIVersions.includes(pluginAPIVersion)) {
    throw new PreviewCliError("plugin-api-unsupported",
      `预览工具支持的插件 API 为 ${result.tool.pluginAPIVersions.join("、")}，插件声明了 ${pluginAPIVersion}。请升级工具包或调整插件 apiVersion。`,
      "unsupported", EXIT.unsupported, { pluginAPIVersion, supported: result.tool.pluginAPIVersions });
  }
}

async function readPluginAPIVersion(pluginDirectory) {
  try {
    const manifest = JSON.parse(await readFile(path.join(pluginDirectory, "manifest.json"), "utf8"));
    return Number.isInteger(manifest.apiVersion) ? manifest.apiVersion : null;
  } catch {
    return null; // manifest 问题由预览工具与 validate 负责报告
  }
}

function emitResult(io, request, result) {
  if (request.json) {
    io.stdout.write(`${JSON.stringify(result)}\n`);
  }
}

function parseToolResult(processResult) {
  if (processResult.stdout.trim() === "") {
    if (processResult.code !== 0 || processResult.signal) {
      throw new PreviewCliError(
        "preview-process-failed",
        "预览工具执行失败",
        "failed",
        EXIT.failed,
      );
    }
    throw environmentError("invalid-tool-output", "预览工具没有输出 JSON 结果");
  }
  let result;
  try {
    result = JSON.parse(processResult.stdout);
  } catch {
    throw environmentError("invalid-tool-output", "预览工具没有输出单一 JSON 结果");
  }
  if (!result || typeof result !== "object" || Array.isArray(result)
      || result.schemaVersion !== 1 || !RESULT_STATUSES.has(result.status)) {
    throw environmentError("invalid-tool-output", "预览工具输出不符合结果契约");
  }
  return result;
}

function statusExitCode(status) {
  if (status === "passed") return EXIT.passed;
  if (status === "unsupported") return EXIT.unsupported;
  if (status === "environment-error") return EXIT.environmentError;
  return EXIT.failed;
}

function parseInspectResult(processResult) {
  if (processResult.stdout.trim() === "") {
    if (processResult.code !== 0 || processResult.signal) {
      throw new PreviewCliError(
        "preview-process-failed",
        "预览工具检查失败；请确认 --preview-tool 指向可运行的 SwitchlyPluginPreview.app。",
        "failed",
        EXIT.failed,
      );
    }
    throw environmentError(
      "invalid-tool-output",
      "预览工具没有输出检查结果 JSON；请确认 --preview-tool 指向兼容的 SwitchlyPluginPreview.app。",
    );
  }
  let result;
  try {
    result = JSON.parse(processResult.stdout);
  } catch {
    throw environmentError(
      "invalid-tool-output",
      "预览工具没有输出单一 JSON 对象；请确认 --preview-tool 指向兼容的 SwitchlyPluginPreview.app。",
    );
  }
  if (!result || typeof result !== "object" || Array.isArray(result) || result.schemaVersion !== 1) {
    throw environmentError("invalid-tool-output", "预览工具输出不符合 inspect 结果契约（schemaVersion 必须为 1）。");
  }
  if (typeof result.status === "string") {
    if (!RESULT_STATUSES.has(result.status)) {
      throw environmentError("invalid-tool-output", "预览工具输出不符合 inspect 结果契约（status 未知）。");
    }
    if (result.status === "passed") {
      throw environmentError("invalid-tool-output", "inspect 不应返回预览运行结果对象；请升级预览工具。");
    }
    const error = result.error && typeof result.error === "object" ? result.error : {};
    throw new PreviewCliError(
      typeof error.code === "string" ? error.code : "inspect-failed",
      typeof error.message === "string" ? error.message : "预览工具检查失败；请修正插件后重试。",
      result.status,
      statusExitCode(result.status),
      error.details,
    );
  }
  if (!result.plugin || typeof result.plugin !== "object" || Array.isArray(result.plugin)) {
    throw environmentError("invalid-tool-output", "检查结果缺少 plugin 字段；请升级预览工具或工具包。");
  }
  return result;
}

function localizedName(name) {
  if (typeof name === "string") return name;
  if (name && typeof name === "object") {
    return name["zh-Hans"] ?? name.en ?? Object.values(name)[0] ?? "";
  }
  return "";
}

function formatScalar(value) {
  if (value === null || value === undefined) return "null";
  if (typeof value === "string") return value;
  return JSON.stringify(value);
}

function formatSetting(setting) {
  const kind = setting.kind ?? setting.type ?? "toggle";
  const details = [`${kind}，默认 ${formatScalar(setting.default)}`];
  if (Array.isArray(setting.options) && setting.options.length > 0) {
    const values = setting.options.map((option) => (
      option && typeof option === "object" ? formatScalar(option.value) : formatScalar(option)
    ));
    details.push(`选项 ${values.join("、")}`);
  }
  if (setting.min !== undefined || setting.max !== undefined) {
    details.push(`范围 ${formatScalar(setting.min ?? "…")}–${formatScalar(setting.max ?? "…")}`);
  }
  if (setting.step !== undefined) details.push(`步长 ${formatScalar(setting.step)}`);
  return `  - ${setting.key ?? "(未命名)"}（${details.join("；")}）`;
}

function formatInspectSummary(result) {
  const plugin = result.plugin;
  const name = localizedName(plugin.name);
  const heading = [
    plugin.id ?? "(未知 ID)",
    name ? `（${name}）` : "",
    plugin.version !== undefined ? ` 版本 ${plugin.version}` : "",
    plugin.apiVersion !== undefined ? `（API ${plugin.apiVersion}）` : "",
  ].join("");
  const lines = [`插件：${heading}`];

  const matches = Array.isArray(plugin.matches) && plugin.matches.length > 0
    ? plugin.matches.join("、")
    : "未声明";
  lines.push(`匹配应用：${matches}`);

  const permissions = Array.isArray(plugin.permissions) && plugin.permissions.length > 0
    ? plugin.permissions.join("、")
    : "无";
  lines.push(`权限：${permissions}`);

  const settings = Array.isArray(result.settings) ? result.settings : [];
  lines.push("可调设置：");
  if (settings.length === 0) lines.push("  （无）");
  else for (const setting of settings) lines.push(formatSetting(setting));

  const fixtures = Array.isArray(result.fixtures) ? result.fixtures : [];
  const neededFixtures = fixtures.filter((fixture) => fixture?.needed);
  lines.push("需要的 fixture：");
  if (neededFixtures.length === 0) {
    lines.push("  （无，默认场景不依赖外部 fixture）");
  } else {
    for (const fixture of neededFixtures) {
      const reason = fixture.reason ? `：${fixture.reason}` : "";
      const hint = fixture.source === "builtin"
        ? "（内置样例，默认场景将自动使用）"
        : fixture.source === "explicit"
          ? "（已提供显式文件）"
          : `（需用 --fixture ${fixture.kind}=<文件> 提供）`;
      lines.push(`  - ${fixture.kind}${hint}${reason}`);
    }
  }

  const scenario = result.defaultScenario && typeof result.defaultScenario === "object"
    ? result.defaultScenario
    : {};
  const environment = scenario.environment ?? {};
  const target = scenario.target ?? {};
  lines.push("默认场景：");
  lines.push(
    `  id=${scenario.id ?? "default"}，语言=${environment.locale ?? "?"}，外观=${environment.appearance ?? "?"}，`
    + `玻璃=${environment.glass ? "开" : "关"}，减少动态效果=${environment.reduceMotion ? "开" : "关"}，`
    + `宽度=${environment.contentWidthPoints ?? "?"}pt`,
  );
  lines.push(`  目标应用=${target.bundleID ?? "?"}（${target.appName ?? "?"}）`);
  if (Array.isArray(scenario.grants)) {
    lines.push(`  权限授予=${scenario.grants.length > 0 ? scenario.grants.join("、") : "无"}`);
  }
  if (scenario.clock) lines.push("  时钟固定：直接 run 可作为视觉基线（玻璃开启时除外）");

  lines.push("下一步：");
  lines.push("  switchly-plugin run <插件目录> --preview-tool <App> --out <输出目录>");
  lines.push("  可加 --locale、--appearance、--glass/--no-glass、--width、--grants、--set、--fixture <kind>=<文件>、--target-bundle-id 覆盖默认场景。");
  lines.push("  需要机器可读的完整结果时加 --json。");
  return lines.join("\n");
}

function runProcess(request, io) {
  return new Promise((resolve, reject) => {
    const sanitize = createSanitizer(request);
    const captureStdout = request.json || request.command === "inspect";
    const stdoutChunks = [];
    let stdoutBytes = 0;
    let stdoutOverflow = false;
    const stdoutWriter = captureStdout ? null : createLineWriter(io.stdout, sanitize);
    const stderrWriter = createLineWriter(io.stderr, sanitize);
    let child;
    try {
      child = io.spawn(request.executable, appArguments(request), {
        stdio: ["inherit", "pipe", "pipe"],
      });
    } catch {
      reject(environmentError("preview-process-launch-failed", "预览工具无法启动"));
      return;
    }

    // 只向 CLI 进程发送终止信号时（脚本、CI、Agent），必须转发给预览进程，否则 App 与 worker 会成为孤儿。
    // 终端里的 Ctrl-C 会发给整个进程组，转发只会重复投递，预览 App 对重复信号是幂等的。
    const forwardedSignals = ["SIGINT", "SIGTERM", "SIGHUP"];
    let escalation = null;
    const forwarders = forwardedSignals.map((name) => {
      const handler = () => {
        try { child.kill(name); } catch { /* 子进程已退出 */ }
        escalation ??= setTimeout(() => {
          try { child.kill("SIGKILL"); } catch { /* 子进程已退出 */ }
        }, FORWARDED_SIGNAL_GRACE_MS);
        escalation.unref?.();
      };
      process.on(name, handler);
      return [name, handler];
    });
    const stopForwarding = () => {
      for (const [name, handler] of forwarders) process.off(name, handler);
      if (escalation) clearTimeout(escalation);
    };

    child.on("error", () => {
      stopForwarding();
      stderrWriter.finish();
      reject(environmentError("preview-process-launch-failed", "预览工具无法启动"));
    });

    child.stdout.on("data", (chunk) => {
      if (!captureStdout) {
        stdoutWriter.push(chunk.toString("utf8"));
        return;
      }
      stdoutBytes += chunk.length;
      if (stdoutBytes > MAX_JSON_OUTPUT_BYTES) {
        stdoutOverflow = true;
        return;
      }
      stdoutChunks.push(chunk);
    });
    child.stderr.on("data", (chunk) => stderrWriter.push(chunk.toString("utf8")));

    child.on("close", (code, signal) => {
      stopForwarding();
      stdoutWriter?.finish();
      stderrWriter.finish();
      if (stdoutOverflow) {
        reject(environmentError("preview-output-too-large", "预览工具输出超过预算"));
        return;
      }
      resolve({
        code: code ?? 1,
        signal,
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
      });
    });
  });
}

/**
 * Schedule the standalone preview app. This module intentionally does not
 * validate plugins, execute JavaScript, write lock files, or manufacture
 * preview artifacts; those responsibilities remain with their owning layers.
 */
export async function runPreviewCommand(command, args, io = {
  stdout: process.stdout,
  stderr: process.stderr,
  spawn,
}) {
  let request;
  try {
    const options = parsePreviewArguments(command, args);
    request = await resolvePreviewRequest(options);
    await checkToolCompatibility(request, io);
    const processResult = await runProcess(request, io);

    if (request.command === "inspect") {
      const result = parseInspectResult(processResult);
      if (processResult.code !== 0) {
        throw environmentError("inconsistent-tool-result", "预览工具的检查结果与退出状态不一致");
      }
      if (request.json) {
        // --json 原样输出预览工具给出的单个 JSON 对象，不重排字段或格式。
        const output = processResult.stdout.endsWith("\n") ? processResult.stdout : `${processResult.stdout}\n`;
        io.stdout.write(output);
      } else {
        writeDiagnostic(io.stdout, formatInspectSummary(result));
      }
      return EXIT.passed;
    }

    if (request.json) {
      const result = parseToolResult(processResult);
      if (result.status === "passed" && processResult.code !== 0) {
        throw environmentError("inconsistent-tool-result", "预览工具结果与退出状态不一致");
      }
      emitResult(io, request, sanitizeJSON(result, createSanitizer(request)));
      return statusExitCode(result.status);
    }

    if (processResult.signal) {
      writeDiagnostic(io.stderr, `错误：预览工具被信号 ${processResult.signal} 终止。`);
      return EXIT.failed;
    }
    return processResult.code;
  } catch (error) {
    const failure = error instanceof PreviewCliError
      ? error
      : environmentError("preview-scheduler-failed", "预览调度失败");
    const jsonMode = args.includes("--json")
      || args.some((arg) => arg.startsWith("--json="));
    if (jsonMode) {
      emitResult(io, { json: true }, failureResult(command, failure));
    }
    writeDiagnostic(io.stderr, `错误：${failure.message}`);
    return failure.exitCode;
  }
}
