import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * CLI 对预览工具的兼容要求。这些值与预览 App 的 `--version-json` 逐项核对：
 * 任何一项不一致都在启动预览之前以可操作的诊断拒绝，而不是在运行中途出现难以定位的错误。
 */
export const CLI_COMPAT = Object.freeze({
  protocolVersion: 1,
  scenarioSchemaVersion: 1,
  toolMajorVersion: 0,
});

// 与 Tools/PluginPreview/contract-hash.sh 使用同一文件集合与顺序。
const CONTRACT_FILES = [
  "preview-activity-fixture.schema.json",
  "capabilities.json",
  "manifest.schema.json",
  "preview-fs-fixture.schema.json",
  "preview-media-fixture.schema.json",
  "preview-scenario.schema.json",
  "preview-weather-fixture.schema.json",
];
const CONTRACT_DIRECTORY = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../contract");
const MAX_VERSION_OUTPUT_BYTES = 16 * 1024;
export const VERSION_QUERY_TIMEOUT_MS = 5_000;

/** 计算 CLI 随包携带的契约哈希：对 "<sha256>  <文件名>\n" 清单再取 sha256。 */
export async function cliContractHash(directory = CONTRACT_DIRECTORY) {
  let manifest = "";
  for (const name of CONTRACT_FILES) {
    const digest = createHash("sha256").update(await readFile(path.join(directory, name))).digest("hex");
    manifest += `${digest}  ${name}\n`;
  }
  return `sha256:${createHash("sha256").update(manifest).digest("hex")}`;
}

/** 返回不兼容项列表；空数组表示工具与 CLI 兼容。 */
export function findMismatches(tool, expectedContractHash) {
  const mismatches = [];
  const add = (field, expected, actual) => mismatches.push({ field, expected: String(expected), actual: String(actual) });
  if (tool.protocolVersion !== CLI_COMPAT.protocolVersion) add("protocolVersion", CLI_COMPAT.protocolVersion, tool.protocolVersion);
  if (tool.scenarioSchemaVersion !== CLI_COMPAT.scenarioSchemaVersion) {
    add("scenarioSchemaVersion", CLI_COMPAT.scenarioSchemaVersion, tool.scenarioSchemaVersion);
  }
  const major = typeof tool.toolVersion === "string" ? Number(tool.toolVersion.split(".")[0]) : Number.NaN;
  if (major !== CLI_COMPAT.toolMajorVersion) add("toolVersion", `${CLI_COMPAT.toolMajorVersion}.x`, tool.toolVersion);
  if (tool.sdkContractHash !== expectedContractHash) add("sdkContractHash", expectedContractHash, tool.sdkContractHash);
  return mismatches;
}

export function parseToolVersion(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  const valid = value && typeof value === "object" && value.tool === "switchly-plugin-preview"
    && typeof value.toolVersion === "string" && Array.isArray(value.pluginAPIVersions)
    && value.pluginAPIVersions.every(Number.isInteger) && typeof value.sdkContractHash === "string";
  return valid ? value : null;
}

/**
 * 运行 `<预览可执行文件> --version-json`。无 GUI、无网络；超时、输出过大或非零退出都视为无法确认兼容。
 * 返回 { tool } 或 { failure: "launch-failed" | "unresponsive" | "no-version-support" | "invalid-output" }。
 */
export function queryToolVersion(executable, spawn) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(executable, ["--version-json"], { stdio: ["ignore", "pipe", "ignore"] });
    } catch {
      resolve({ failure: "launch-failed" });
      return;
    }
    const chunks = [];
    let bytes = 0;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch { /* 已退出 */ }
      finish({ failure: "unresponsive" });
    }, VERSION_QUERY_TIMEOUT_MS);
    child.on("error", () => finish({ failure: "launch-failed" }));
    child.stdout.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > MAX_VERSION_OUTPUT_BYTES) {
        try { child.kill("SIGKILL"); } catch { /* 已退出 */ }
        finish({ failure: "invalid-output" });
        return;
      }
      chunks.push(chunk);
    });
    child.on("close", (code) => {
      if (settled) return;
      if (code !== 0) { finish({ failure: "no-version-support" }); return; }
      const tool = parseToolVersion(Buffer.concat(chunks).toString("utf8"));
      finish(tool ? { tool } : { failure: "invalid-output" });
    });
  });
}
