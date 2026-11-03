import { spawn } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import {
  access,
  lstat,
  readdir,
  realpath,
  stat,
} from "node:fs/promises";
import path from "node:path";

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
const RESULT_STATUSES = new Set(["passed", "failed", "unsupported", "environment-error"]);

class PreviewCliError extends Error {
  constructor(code, message, status = "failed", exitCode = EXIT.failed) {
    super(message);
    this.code = code;
    this.status = status;
    this.exitCode = exitCode;
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
    if (!value || value.startsWith("--")) throw argumentError(`${name} 缺少值`);
    return { value, consumed: 2 };
  }
  const prefix = `${name}=`;
  if (arg.startsWith(prefix)) {
    const value = arg.slice(prefix.length);
    if (!value) throw argumentError(`${name} 缺少值`);
    return { value, consumed: 1 };
  }
  return null;
}

/**
 * Parse only the public CLI surface. Filesystem and preview-tool checks happen
 * after all arguments have been validated so usage errors never launch a tool.
 */
export function parsePreviewArguments(command, args) {
  if (!["dev", "run"].includes(command)) {
    throw argumentError("预览命令必须是 dev 或 run");
  }

  const options = {
    command,
    json: false,
    previewTool: null,
    scenario: null,
    out: null,
    plugin: null,
  };
  const positional = [];

  for (let index = 0; index < args.length;) {
    const arg = args[index];
    if (arg === "--json") {
      if (options.json) throw argumentError("--json 不能重复");
      options.json = true;
      index += 1;
      continue;
    }

    let parsed = optionValue(args, index, "--preview-tool");
    if (parsed) {
      if (options.previewTool !== null) throw argumentError("--preview-tool 不能重复");
      options.previewTool = parsed.value;
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--scenario");
    if (parsed) {
      if (options.scenario !== null) throw argumentError("--scenario 不能重复");
      options.scenario = parsed.value;
      index += parsed.consumed;
      continue;
    }

    parsed = optionValue(args, index, "--out");
    if (parsed) {
      if (command !== "run") throw argumentError("dev 不接受 --out");
      if (options.out !== null) throw argumentError("--out 不能重复");
      options.out = parsed.value;
      index += parsed.consumed;
      continue;
    }

    if (arg.startsWith("--")) throw argumentError("包含未知参数");
    positional.push(arg);
    index += 1;
  }

  if (positional.length !== 1) throw argumentError(`${command} 需要一个插件目录`);
  options.plugin = positional[0];
  if (!options.previewTool) throw argumentError("缺少 --preview-tool");
  if (!options.scenario) throw argumentError("缺少 --scenario");
  if (command === "run" && !options.out) throw argumentError("run 缺少 --out");
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
  const scenario = path.resolve(options.scenario);
  await requireDirectory(plugin, "插件目录");
  await requireFile(scenario, "场景文件");
  const pluginRealPath = await realpath(plugin);
  const scenarioRealPath = await realpath(scenario);
  const previewTool = await resolvePreviewTool(options.previewTool);
  let out = null;

  if (options.command === "run") {
    out = await inspectOutputDirectory(path.resolve(options.out));
    if (isWithin(pluginRealPath, out) || isWithin(out, pluginRealPath)) {
      throw argumentError("--out 不能与插件源码目录重叠");
    }
  }

  return {
    command: options.command,
    json: options.json,
    plugin: pluginRealPath,
    scenario: scenarioRealPath,
    out,
    previewTool: previewTool.appDirectory,
    executable: previewTool.executable,
  };
}

function appArguments(request) {
  const args = [
    request.command,
    request.plugin,
    "--scenario", request.scenario,
  ];
  if (request.command === "run") args.push("--out", request.out);
  if (request.json) args.push("--json");
  return args;
}

function createSanitizer(request) {
  const replacements = [
    [request.executable, "<preview-executable>"],
    [request.previewTool, "<preview-tool>"],
    [request.scenario, "<scenario-path>"],
    [request.plugin, "<plugin-path>"],
  ];
  if (request.out) replacements.push([request.out, "<output-path>"]);
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
    },
  };
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

function runProcess(request, io) {
  return new Promise((resolve, reject) => {
    const sanitize = createSanitizer(request);
    const stdoutChunks = [];
    let stdoutBytes = 0;
    let stdoutOverflow = false;
    const stdoutWriter = request.json ? null : createLineWriter(io.stdout, sanitize);
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

    child.on("error", () => {
      stderrWriter.finish();
      reject(environmentError("preview-process-launch-failed", "预览工具无法启动"));
    });

    child.stdout.on("data", (chunk) => {
      if (!request.json) {
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
    const processResult = await runProcess(request, io);

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
