import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import path from "node:path";
import { PngError, decodePng, encodePng } from "./png.js";

const EXIT = Object.freeze({ passed: 0, failed: 1, invalidArguments: 2, environmentError: 4 });
const MAX_REPORT_BYTES = 1024 * 1024;
const MAX_PNG_BYTES = 32 * 1024 * 1024;
const NAME_PATTERN = /^[A-Za-z0-9._-]{1,200}$/;
// 兼容指纹：任一字段不同都不能比较像素（系统/字体/缩放/渲染器变化会让差异失去意义）。
const FINGERPRINT_FIELDS = ["osMajor", "architecture", "displayScale", "rendererRevision", "toolVersion", "locale", "appearance"];

class BaselineError extends Error {
  constructor(code, message, status = "failed", exitCode = EXIT.failed, extra = {}) {
    super(message);
    this.code = code;
    this.status = status;
    this.exitCode = exitCode;
    this.extra = extra;
  }
}

const invalid = (message) => new BaselineError("invalid-arguments", message, "failed", EXIT.invalidArguments);

function parseArguments(command, args) {
  const options = { command, runDirectory: null, baselineDirectory: null, out: null, tolerance: 0, replace: false, json: false };
  const valued = new Map([["--baseline-dir", "baselineDirectory"], ["--out", "out"], ["--tolerance", "tolerance"]]);
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--json") options.json = true;
    else if (arg === "--replace") options.replace = true;
    else if (valued.has(arg)) {
      const value = args[index + 1];
      if (value === undefined || value.startsWith("--")) throw invalid(`${arg} 缺少值`);
      options[valued.get(arg)] = value;
      index += 1;
    } else if (arg.startsWith("--")) throw invalid(`未知选项：${arg}`);
    else if (options.runDirectory === null) options.runDirectory = arg;
    else throw invalid("只接受一个 run 输出目录");
  }
  if (!options.runDirectory) throw invalid("缺少 run 输出目录");
  if (!options.baselineDirectory) throw invalid("缺少 --baseline-dir");
  if (command === "compare" && !options.out) throw invalid("compare 需要 --out");
  if (command === "accept" && (options.out || options.tolerance !== 0)) throw invalid("accept 不接受 --out/--tolerance");
  if (command === "compare") {
    const tolerance = Number(options.tolerance);
    if (!Number.isInteger(tolerance) || tolerance < 0 || tolerance > 255) throw invalid("--tolerance 必须是 0 到 255 的整数");
    options.tolerance = tolerance;
  }
  return options;
}

async function readBounded(file, limit, code) {
  let info;
  try {
    info = await lstat(file);
  } catch {
    throw new BaselineError(code, "文件不存在或不可读");
  }
  if (info.isSymbolicLink() || !info.isFile() || info.size > limit) throw new BaselineError(code, "文件不是受限制的普通文件");
  return readFile(file);
}

async function loadRun(runDirectory) {
  const directory = await realpath(path.resolve(runDirectory)).catch(() => {
    throw new BaselineError("run-not-found", "run 输出目录不存在");
  });
  let report;
  try {
    report = JSON.parse((await readBounded(path.join(directory, "report.json"), MAX_REPORT_BYTES, "report-unreadable")).toString("utf8"));
  } catch (error) {
    if (error instanceof BaselineError) throw error;
    throw new BaselineError("report-unreadable", "report.json 不是有效 JSON");
  }
  if (report?.schemaVersion !== 1 || typeof report.pluginID !== "string" || typeof report.scenarioID !== "string") {
    throw new BaselineError("report-invalid", "report.json 不符合预览报告契约");
  }
  if (report.status !== "passed") throw new BaselineError("run-not-passed", "只有 passed 的 run 才能用作基线或比较");
  if (!report.artifacts?.screenshot) throw new BaselineError("screenshot-missing", "run 没有截图产物");
  const screenshot = await readBounded(path.join(directory, report.artifacts.screenshot), MAX_PNG_BYTES, "screenshot-unreadable");
  return { report, screenshot };
}

function nameFor(report) {
  const key = `${report.pluginID}__${report.scenarioID}`;
  if (!NAME_PATTERN.test(report.pluginID) || !NAME_PATTERN.test(report.scenarioID) || key.length > 200) {
    throw new BaselineError("identity-unsafe", "插件或场景 ID 含不允许用于基线目录的字符");
  }
  return key;
}

function fingerprintOf(report) {
  const environment = report.environment ?? {};
  return {
    osMajor: typeof environment.operatingSystemVersion === "string" ? environment.operatingSystemVersion.split(".")[0] : null,
    architecture: environment.architecture ?? null,
    displayScale: environment.displayScale ?? null,
    rendererRevision: environment.rendererRevision ?? null,
    toolVersion: report.versions?.toolVersion ?? null,
    locale: environment.locale ?? null,
    appearance: environment.appearance ?? null,
  };
}

function sha256(buffer) {
  return `sha256:${createHash("sha256").update(buffer).digest("hex")}`;
}

function requireStableRun(report) {
  if (report.environment?.glass !== false) {
    throw new BaselineError("not-a-stable-baseline", "玻璃或未知材质的截图依赖桌面背景，只能作为证据，不能作为基线");
  }
  if (report.environment?.deterministicClock !== true) {
    throw new BaselineError("not-a-stable-baseline", "场景未声明 clock，截图随时间变化，不能作为基线");
  }
  const fingerprint = fingerprintOf(report);
  const missing = FINGERPRINT_FIELDS.filter((field) => fingerprint[field] === null);
  if (missing.length > 0) throw new BaselineError("fingerprint-incomplete", `报告缺少环境指纹：${missing.join(",")}`);
}

async function accept(options) {
  const { report, screenshot } = await loadRun(options.runDirectory);
  requireStableRun(report);
  const image = decodePng(screenshot);
  const directory = path.join(path.resolve(options.baselineDirectory), nameFor(report));
  const exists = await lstat(path.join(directory, "baseline.json")).then(() => true, () => false);
  if (exists && !options.replace) {
    throw new BaselineError("baseline-exists", "基线已存在；确认要替换请显式传 --replace");
  }
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, "baseline.png"), screenshot);
  const meta = {
    schemaVersion: 1,
    identity: { pluginID: report.pluginID, scenarioID: report.scenarioID },
    fingerprint: fingerprintOf(report),
    provenance: {
      packageHash: report.packageHash,
      pluginVersion: report.pluginVersion,
      sdkContractHash: report.versions?.sdkContractHash ?? null,
    },
    png: { width: image.width, height: image.height, sha256: sha256(screenshot) },
  };
  await writeFile(path.join(directory, "baseline.json"), `${JSON.stringify(meta, null, 2)}\n`);
  return { schemaVersion: 1, command: "baseline-accept", status: "passed", identity: meta.identity, replaced: exists };
}

async function loadBaseline(options, report) {
  const directory = path.join(path.resolve(options.baselineDirectory), nameFor(report));
  let meta;
  try {
    meta = JSON.parse((await readBounded(path.join(directory, "baseline.json"), MAX_REPORT_BYTES, "baseline-missing")).toString("utf8"));
  } catch (error) {
    if (error instanceof BaselineError) throw new BaselineError("baseline-missing", "没有该插件与场景的基线；先显式运行 baseline accept");
    throw new BaselineError("baseline-invalid", "baseline.json 不是有效 JSON");
  }
  const png = await readBounded(path.join(directory, "baseline.png"), MAX_PNG_BYTES, "baseline-missing");
  if (meta?.schemaVersion !== 1 || meta.png?.sha256 !== sha256(png)) {
    throw new BaselineError("baseline-invalid", "基线图片与其元数据不一致（文件被改动？）");
  }
  return { meta, png };
}

async function prepareOutput(out) {
  const target = path.resolve(out);
  await mkdir(target, { recursive: true });
  if ((await readdir(target)).length > 0) throw new BaselineError("output-not-empty", "--out 必须是空目录");
  return target;
}

function compareImages(baseline, current, tolerance) {
  const diffRGBA = new Uint8Array(current.width * current.height * 4);
  let pixels = 0;
  let maxChannel = 0;
  let minX = Infinity; let minY = Infinity; let maxX = -1; let maxY = -1;
  for (let y = 0; y < current.height; y += 1) {
    for (let x = 0; x < current.width; x += 1) {
      const offset = (y * current.width + x) * 4;
      let worst = 0;
      for (let channel = 0; channel < 4; channel += 1) {
        worst = Math.max(worst, Math.abs(baseline.rgba[offset + channel] - current.rgba[offset + channel]));
      }
      // 未变化像素压暗保留轮廓，变化像素标红。
      const grey = (current.rgba[offset] + current.rgba[offset + 1] + current.rgba[offset + 2]) / 3;
      if (worst > tolerance) {
        pixels += 1;
        maxChannel = Math.max(maxChannel, worst);
        minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
        diffRGBA.set([255, 0, 0, 255], offset);
      } else {
        const dim = Math.round(grey * 0.35 + 40);
        diffRGBA.set([dim, dim, dim, 255], offset);
      }
    }
  }
  const diff = { pixels, ratio: pixels / (current.width * current.height), maxChannelDifference: maxChannel,
    boundingBox: pixels === 0 ? null : { x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1 } };
  return { diff, diffImage: { width: current.width, height: current.height, rgba: diffRGBA } };
}

async function compare(options) {
  const { report, screenshot } = await loadRun(options.runDirectory);
  requireStableRun(report);
  const { meta, png } = await loadBaseline(options, report);
  const identity = { pluginID: report.pluginID, scenarioID: report.scenarioID };
  const current = fingerprintOf(report);
  const mismatched = FINGERPRINT_FIELDS.filter((field) => meta.fingerprint?.[field] !== current[field]);
  if (mismatched.length > 0) {
    throw new BaselineError("incompatible-environment", "环境与基线不兼容，不能比较像素；请在相同环境重跑或显式重新接受基线",
      "environment-error", EXIT.environmentError, { identity, mismatchedFields: mismatched });
  }
  const output = await prepareOutput(options.out);
  const baselineImage = decodePng(png);
  const currentImage = decodePng(screenshot);
  const packageChanged = meta.provenance?.packageHash !== report.packageHash;
  const base = { schemaVersion: 1, command: "baseline-compare", identity, tolerance: options.tolerance, packageChanged,
    baseline: { width: baselineImage.width, height: baselineImage.height }, current: { width: currentImage.width, height: currentImage.height } };
  let result;
  if (baselineImage.width !== currentImage.width || baselineImage.height !== currentImage.height) {
    result = { ...base, status: "failed", failure: { code: "size-changed" } };
  } else {
    const { diff, diffImage } = compareImages(baselineImage, currentImage, options.tolerance);
    if (diff.pixels === 0) result = { ...base, status: "passed", diff };
    else {
      await writeFile(path.join(output, "diff.png"), encodePng(diffImage));
      result = { ...base, status: "failed", failure: { code: "visual-diff" }, diff, artifacts: { diff: "diff.png" } };
    }
  }
  await writeFile(path.join(output, "compare-report.json"), `${JSON.stringify(result, null, 2)}\n`);
  return result;
}

export async function runBaselineCommand(args, io = { stdout: process.stdout, stderr: process.stderr }) {
  const [command, ...rest] = args;
  let options;
  try {
    if (command !== "accept" && command !== "compare") throw invalid("baseline 子命令必须是 accept 或 compare");
    options = parseArguments(command, rest);
    const result = command === "accept" ? await accept(options) : await compare(options);
    io.stdout.write(options.json ? `${JSON.stringify(result)}\n` : `${result.command}: ${result.status}\n`);
    return result.status === "passed" ? EXIT.passed : EXIT.failed;
  } catch (error) {
    const failure = error instanceof BaselineError
      ? error
      : error instanceof PngError
        ? new BaselineError(error.code, "PNG 无法解码或不受支持")
        : new BaselineError("baseline-internal-error", "基线处理失败", "environment-error", EXIT.environmentError);
    const result = { schemaVersion: 1, command: `baseline-${command ?? "unknown"}`, status: failure.status,
      error: { code: failure.code, message: failure.message }, ...failure.extra };
    if (rest.includes("--json")) io.stdout.write(`${JSON.stringify(result)}\n`);
    io.stderr.write(`错误：${failure.message}\n`);
    return failure.exitCode;
  }
}
