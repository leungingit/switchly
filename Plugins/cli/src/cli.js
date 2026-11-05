import { spawnSync } from "node:child_process";
import {
  cp,
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runPreviewCommand } from "./preview.js";
import { runBaselineCommand } from "./baseline.js";
import { validatePluginDirectory } from "./validate.js";

const capabilitiesURL = new URL("../contract/capabilities.json", import.meta.url);

const help = `Switchly 插件 CLI

用法：
  switchly-plugin api describe --json
  switchly-plugin validate <插件目录> [--json]
  switchly-plugin build <插件目录> [--out <输出根目录>] [--json]
  switchly-plugin verify <插件目录> --host <宿主校验工具路径>
  switchly-plugin create <目标目录> [--id <插件ID>] [--name <名称>] [--match <bundleID>] [--json]
  switchly-plugin inspect <插件目录> --preview-tool <App> [--json]
  switchly-plugin dev <插件目录> --preview-tool <App> [--scenario <场景> | 覆盖项…] [--json]
  switchly-plugin run <插件目录> --preview-tool <App> [--scenario <场景> | 覆盖项…] --out <输出目录> [--json]
  switchly-plugin baseline accept <run输出目录> --baseline-dir <基线目录> [--replace] [--json]
  switchly-plugin baseline compare <run输出目录> --baseline-dir <基线目录> --out <差异输出目录> [--tolerance 0-255] [--json]

覆盖项（仅当未提供 --scenario 时可用）：
  --locale en|zh-Hans            --appearance light|dark
  --glass | --no-glass           --reduce-motion | --no-reduce-motion
  --width <点数>                 --grants <a,b,c|none>
  --set <key=value>（可重复）    --fixture <media|weather|fs>=<文件>（可重复）
  --target-bundle-id <id>        --target-app-name <名称>

说明：
  validate  检查 manifest、入口、设置唯一性、权限和静态资源路径。
  build     在 validate 通过后原样复制到 <输出根目录>/<插件 id>。
            默认输出根目录为当前目录下的 .build/Plugins。
            该命令不做 TypeScript 转译或 JavaScript 打包。
  create    创建不依赖外部模板的最小零依赖插件，并立即运行 validate。
            默认渲染到 center 槽位，创建后无需场景文件即可直接 run。
  inspect   无 GUI 检查插件：输出版本握手结果、默认场景、可调设置与所需 fixture。
            --json 原样输出单个 JSON 对象；否则打印人类可读摘要。
  dev       启动独立预览 App；不转译 TypeScript，也不更新插件锁。
  run       执行一次独立预览并写入调用者指定的输出目录。
  baseline  视觉基线：accept 显式接受 run 的截图为基线；compare 与基线像素比较并输出差异图。
            仅接受确定时钟且非玻璃的 run；环境指纹不一致时拒绝比较，不会自动接受或放宽阈值。
`;

function optionValue(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return null;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${name} 缺少值`);
  return value;
}

async function loadCapabilities() {
  try {
    return JSON.parse(await readFile(fileURLToPath(capabilitiesURL), "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    // 源码检出首次调用尚未 prepack；发行包始终带 contract。
    return JSON.parse(await readFile(new URL("../../api/capabilities.json", import.meta.url), "utf8"));
  }
}

async function apiDescribe(args) {
  if (args.includes("--help") || args.includes("-h")) {
    process.stdout.write("用法：switchly-plugin api describe --json\n");
    return 0;
  }
  if (args.length !== 1 || args[0] !== "--json") {
    throw new Error("api describe 当前只支持 --json");
  }
  const capabilities = await loadCapabilities();
  process.stdout.write(`${JSON.stringify(capabilities, null, 2)}\n`);
  return 0;
}

function printValidation(result, asJSON) {
  if (asJSON) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (result.ok) {
    process.stdout.write(`通过：${result.id ?? result.directory}\n`);
  } else {
    process.stdout.write(`失败：${result.directory}\n`);
  }
  for (const warning of result.warnings) process.stdout.write(`警告：${warning}\n`);
  for (const error of result.errors) process.stdout.write(`错误：${error}\n`);
}

async function validateCommand(args) {
  const asJSON = args.includes("--json");
  const positional = args.filter((arg) => arg !== "--json");
  if (positional.length !== 1) throw new Error("validate 需要一个插件目录");
  const result = await validatePluginDirectory(positional[0]);
  printValidation(result, asJSON);
  return result.ok ? 0 : 1;
}

async function buildCommand(args) {
  const asJSON = args.includes("--json");
  const outRoot = optionValue(args, "--out");
  const positional = [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "--json") continue;
    if (args[index] === "--out") {
      index += 1;
      continue;
    }
    positional.push(args[index]);
  }
  if (positional.length !== 1) throw new Error("build 需要一个插件目录");

  const result = await validatePluginDirectory(positional[0]);
  if (!result.ok) {
    printValidation(result, asJSON);
    return 1;
  }

  const destinationRoot = path.resolve(outRoot ?? path.join(process.cwd(), ".build", "Plugins"));
  const destination = path.join(destinationRoot, result.id);
  const relative = path.relative(result.directory, destination);
  const sourceRelative = path.relative(destination, result.directory);
  if (relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative))
    || (!sourceRelative.startsWith("..") && !path.isAbsolute(sourceRelative))) {
    throw new Error("输出目录不能与插件源码重叠");
  }
  await mkdir(destinationRoot, { recursive: true });
  await rm(destination, { recursive: true, force: true });
  await cp(result.directory, destination, { recursive: true });
  const output = {
    ...result,
    artifact: destination,
    compiled: false,
  };
  if (asJSON) {
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  } else {
    printValidation(result, false);
    process.stdout.write(`已复制：${destination}\n未执行 TypeScript 转译或 JavaScript 打包。\n`);
  }
  return 0;
}

function defaultPluginID(directory) {
  const slug = path.basename(directory)
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    || "example";
  return `com.example.${slug}`;
}

async function createCommand(args) {
  const asJSON = args.includes("--json");
  const id = optionValue(args, "--id");
  const name = optionValue(args, "--name");
  const match = optionValue(args, "--match");
  const positional = [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "--json") continue;
    if (["--id", "--name", "--match"].includes(args[index])) {
      index += 1;
      continue;
    }
    positional.push(args[index]);
  }
  if (positional.length !== 1) throw new Error("create 需要一个目标目录");

  const directory = path.resolve(positional[0]);
  let existing = [];
  try {
    existing = await readdir(directory);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (existing.length > 0) throw new Error(`目标目录非空：${directory}`);

  const pluginID = id ?? defaultPluginID(directory);
  const displayName = name ?? "Switchly Plugin";
  await mkdir(path.join(directory, "locales"), { recursive: true });
  await writeFile(path.join(directory, "manifest.json"), `${JSON.stringify({
    id: pluginID,
    name: { en: displayName, "zh-Hans": displayName },
    version: "0.1.0",
    apiVersion: 2,
    summary: {
      en: "A minimal Switchly plugin",
      "zh-Hans": "一个最小 Switchly 插件",
    },
    matches: [match ?? "com.example.target"],
    permissions: [],
    entry: "main.js",
  }, null, 2)}\n`);
  await writeFile(path.join(directory, "main.js"), `// Switchly 插件入口：宿主在独立 worker 中加载本文件，并调用 globalThis.__switchlyPlugin。
globalThis.__switchlyPlugin = {
  // render 返回要展示的节点数组；"center" 是面板主体（预览可捕获的槽位），
  // "titleAccessory" 是标题旁的附加槽位。返回空数组表示本次不渲染。
  render(ctx) {
    return [{
      slot: "center",
      node: { type: "badge", value: "Ready", tone: "accent" }
    }];
  }

  // 可选：onAction 接收交互动作（id 为节点 action id，value 为可选数值）。
  // onAction(action, ctx) {
  //   console.log("action", action.id);
  // }
};
`);
  await writeFile(
    path.join(directory, "locales", "en.json"),
    `${JSON.stringify({ Ready: "Ready" }, null, 2)}\n`,
  );
  await writeFile(
    path.join(directory, "locales", "zh-Hans.json"),
    `${JSON.stringify({ Ready: "就绪" }, null, 2)}\n`,
  );

  const validation = await validatePluginDirectory(directory);
  const output = {
    ok: validation.ok,
    directory,
    id: pluginID,
    created: true,
    validation,
  };
  if (asJSON) {
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  } else if (validation.ok) {
    process.stdout.write(`已创建并验证：${directory}\n插件 ID：${pluginID}\n`);
  } else {
    printValidation(validation, false);
  }
  return validation.ok ? 0 : 1;
}

async function verifyCommand(args) {
  const host = optionValue(args, "--host");
  const hostIndex = args.indexOf("--host");
  const positional = args.filter((_, index) => index !== hostIndex && index !== hostIndex + 1);
  if (!host || positional.length !== 1) throw new Error("verify 需要插件目录和 --host 工具路径");
  const validation = await validatePluginDirectory(positional[0]);
  if (!validation.ok) { printValidation(validation, false); return 1; }
  const result = spawnSync(path.resolve(host), [validation.directory], { encoding: "utf8", timeout: 5000, killSignal: "SIGKILL" });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw new Error("宿主校验进程失败或超过5秒预算");
  return result.status ?? 1;
}

export async function main(args) {
  try {
    if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
      process.stdout.write(help);
      return 0;
    }
    if (args[0] === "api" && args[1] === "describe") {
      return await apiDescribe(args.slice(2));
    }
    if (args[0] === "verify") return await verifyCommand(args.slice(1));
    if (args[0] === "validate") return await validateCommand(args.slice(1));
    if (args[0] === "build") return await buildCommand(args.slice(1));
    if (args[0] === "create") return await createCommand(args.slice(1));
    if (args[0] === "baseline") return await runBaselineCommand(args.slice(1));
    if (args[0] === "dev" || args[0] === "run" || args[0] === "inspect") {
      return await runPreviewCommand(args[0], args.slice(1));
    }
    throw new Error(`未知命令：${args[0]}`);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    return 2;
  }
}
