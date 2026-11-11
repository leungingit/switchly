import {
  lstat,
  readFile,
  readdir,
  realpath,
  stat,
} from "node:fs/promises";
import path from "node:path";

import {
  GLBError,
  glbAllowedExtensions,
  glbLimits,
  inspectGLB,
} from "./glb.js";

const allowedPermissions = new Set([
  "media.nowPlaying",
  "media.control",
  "media.library",
  "weather.current",
  "window.focus",
  "window.capture",
  "fs.read",
]);

const sensitiveHomeRoots = [
  ".ssh",
  ".aws",
  ".gnupg",
  ".codex",
  ".kube",
  ".docker",
  ".config/gcloud",
  "Library/Keychains",
  "Library/Cookies",
  "Library/Safari",
  "Library/Application Support/Google/Chrome",
  "Library/Application Support/Firefox",
  "Library/Application Support/BraveSoftware",
  "Library/Application Support/Microsoft Edge",
];

const secretFileNames = new Set(["auth.json", ".env", ".credentials.yaml"]);
const packageLimits = Object.freeze({
  maxPackageBytes: 32 * 1024 * 1024,
  maxEntries: 1024,
  maxManifestBytes: 256 * 1024,
  maxEntryBytes: 2 * 1024 * 1024,
});
const idPattern = /^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$/;
const rootIDPattern = /^[A-Za-z0-9_-]+$/;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isLocalizedText(value) {
  return isObject(value)
    && Object.keys(value).length > 0
    && Object.values(value).every((item) => typeof item === "string" && item.trim().length > 0);
}

function isSafeRelativePath(value) {
  return typeof value === "string"
    && value.length > 0
    && !path.posix.isAbsolute(value)
    && !value.split("/").includes("..")
    && !value.includes("\0");
}

function isWithin(base, target) {
  const relative = path.relative(base, target);
  return relative !== "" && !relative.startsWith("..") && !path.isAbsolute(relative);
}

function lexicalFSPathIssue(value) {
  if (typeof value !== "string" || value.length === 0) return "路径不能为空";
  if (!(value.startsWith("/") || value.startsWith("~/"))) {
    return "路径必须以 / 或 ~/ 开头";
  }
  if (value.split("/").includes("..")) return "路径不能包含 ..";
  if (value.includes("\0")) return "路径不能包含 NUL";
  if (value.startsWith("~/")) {
    const relative = value.slice(2);
    if (sensitiveHomeRoots.some((root) => relative === root || relative.startsWith(`${root}/`))) {
      return "路径位于宿主拒绝的敏感目录";
    }
  }
  return null;
}

async function readJSON(file, label, errors) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    errors.push(`${label} 无法读取或不是合法 JSON：${error.message}`);
    return null;
  }
}

async function validatePackageEntries(pluginDir, errors) {
  const models = [];
  let rootInfo;
  try {
    rootInfo = await lstat(pluginDir);
    if (rootInfo.isSymbolicLink()) {
      errors.push("插件包根目录不能是符号链接");
    }
  } catch (error) {
    errors.push(`插件目录不存在或不可读：${error.message}`);
    return models;
  }
  if (!rootInfo.isDirectory()) {
    errors.push("插件路径不是目录");
    return models;
  }

  let entries = 0;
  let bytes = 0;
  async function walk(directory) {
    let children;
    try {
      children = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      errors.push(`目录不可读：${path.relative(pluginDir, directory)} (${error.message})`);
      return;
    }
    for (const child of children) {
      entries += 1;
      if (entries > packageLimits.maxEntries) {
        errors.push(`插件包条目超过 ${packageLimits.maxEntries}`);
        return;
      }
      const target = path.join(directory, child.name);
      if (child.isSymbolicLink()) {
        errors.push(`插件包禁止符号链接：${path.relative(pluginDir, target)}`);
        continue;
      }
      if (child.isDirectory()) {
        await walk(target);
        continue;
      }
      if (!child.isFile()) {
        errors.push(`插件包含不支持的文件类型：${path.relative(pluginDir, target)}`);
        continue;
      }
      const info = await stat(target);
      bytes += info.size;
      if (bytes > packageLimits.maxPackageBytes) {
        errors.push(`插件包超过 ${packageLimits.maxPackageBytes} bytes`);
        return;
      }
      if (child.name.toLowerCase().endsWith(".glb")) {
        models.push({
          file: target,
          relative: path.relative(pluginDir, target),
          size: info.size,
        });
      }
    }
  }
  await walk(pluginDir);
  return models;
}

async function validateModels(models, errors) {
  for (const model of models) {
    if (model.size > glbLimits.maxFileBytes) {
      errors.push(`3D 资产预检失败：${model.relative}（glb-exceeds-byte-budget：glb exceeds byte budget）`);
      continue;
    }
    let data;
    try {
      data = await readFile(model.file);
    } catch (error) {
      errors.push(`3D 资产预检失败：${model.relative}（无法读取：${error.message}）`);
      continue;
    }
    try {
      inspectGLB(data);
    } catch (error) {
      if (error instanceof GLBError) {
        const detail = error.reason === error.code
          ? error.code
          : `${error.code}：${error.reason}`;
        errors.push(`3D 资产预检失败：${model.relative}（${detail}）`);
      } else {
        errors.push(`3D 资产预检失败：${model.relative}（${error.message}）`);
      }
    }
  }
}

function validateSettings(settings, errors) {
  if (settings === undefined || settings === null) return;
  if (!Array.isArray(settings)) {
    errors.push("settings 必须是数组");
    return;
  }
  const seen = new Set();
  settings.forEach((setting, index) => {
    const where = `settings[${index}]`;
    if (!isObject(setting)) {
      errors.push(`${where} 必须是对象`);
      return;
    }
    if (typeof setting.key !== "string" || setting.key.length === 0) {
      errors.push(`${where}.key 必须是非空字符串`);
    } else if (seen.has(setting.key)) {
      errors.push(`设置 key 重复：${setting.key}`);
    } else {
      seen.add(setting.key);
    }
    if (!isLocalizedText(setting.title)) {
      errors.push(`${where}.title 必须是非空的本地化字符串对象`);
    }

    const kind = setting.type ?? "toggle";
    if (!["toggle", "select", "number"].includes(kind)) {
      errors.push(`${where}.type 未知：${String(kind)}`);
      return;
    }
    if (setting.effect !== undefined && setting.effect !== "hideWindowPreviews") {
      errors.push(`${where}.effect 必须是 hideWindowPreviews`);
    }

    if (kind === "toggle") {
      if (typeof setting.default !== "boolean") {
        errors.push(`${where}.default 对 toggle 必须是 boolean`);
      }
      return;
    }

    if (kind === "select") {
      if (!Array.isArray(setting.options) || setting.options.length === 0) {
        errors.push(`${where}.options 对 select 必须是非空数组`);
        return;
      }
      const values = new Set();
      setting.options.forEach((option, optionIndex) => {
        const optionWhere = `${where}.options[${optionIndex}]`;
        if (!isObject(option)) {
          errors.push(`${optionWhere} 必须是对象`);
          return;
        }
        if (typeof option.value !== "string") {
          errors.push(`${optionWhere}.value 必须是 string`);
        } else if (values.has(option.value)) {
          errors.push(`${where} 的 option value 重复：${option.value}`);
        } else {
          values.add(option.value);
        }
        if (!isLocalizedText(option.title)) {
          errors.push(`${optionWhere}.title 必须是非空的本地化字符串对象`);
        }
      });
      if (typeof setting.default !== "string") {
        errors.push(`${where}.default 对 select 必须是 string`);
      } else if (!values.has(setting.default)) {
        errors.push(`${where}.default 不在 options 中：${setting.default}`);
      }
      return;
    }

    if (typeof setting.default !== "number" || !Number.isFinite(setting.default)) {
      errors.push(`${where}.default 对 number 必须是有限数字`);
    }
    for (const key of ["min", "max", "step"]) {
      if (setting[key] !== undefined
          && (typeof setting[key] !== "number" || !Number.isFinite(setting[key]))) {
        errors.push(`${where}.${key} 必须是有限数字`);
      }
    }
    if (typeof setting.step === "number" && setting.step <= 0) {
      errors.push(`${where}.step 必须大于 0`);
    }
    if (typeof setting.min === "number"
        && typeof setting.max === "number"
        && setting.min > setting.max) {
      errors.push(`${where}.min 不能大于 max`);
    }
    if (typeof setting.default === "number") {
      if (typeof setting.min === "number" && setting.default < setting.min) {
        errors.push(`${where}.default 小于 min`);
      }
      if (typeof setting.max === "number" && setting.default > setting.max) {
        errors.push(`${where}.default 大于 max`);
      }
    }
  });
}

/**
 * Validate the host-owned manifest contract without touching the plugin filesystem.
 * Repository-specific policies such as asset budgets and locale pairing stay with
 * their caller so they can remain stricter than the host contract.
 */
export function validateManifest(manifest) {
  const errors = [];
  const warnings = [];
  if (!isObject(manifest)) {
    errors.push("manifest 顶层必须是对象");
    return { ok: false, id: null, permissions: [], errors, warnings };
  }

  let id = null;
  if (typeof manifest.id !== "string" || !idPattern.test(manifest.id)) {
    errors.push("id 必须匹配 ^[A-Za-z0-9]+(\\.[A-Za-z0-9-]+)+$");
  } else {
    id = manifest.id;
  }
  if (!isLocalizedText(manifest.name)) {
    errors.push("name 必须是非空的本地化字符串对象");
  }
  if (typeof manifest.version !== "string" || manifest.version.length === 0) {
    errors.push("version 必须是非空字符串");
  }
  if (!Number.isInteger(manifest.apiVersion) || ![1, 2].includes(manifest.apiVersion)) {
    errors.push("apiVersion 必须是 1 或 2");
  }
  if (!Array.isArray(manifest.matches) || manifest.matches.length === 0
      || !manifest.matches.every((item) => typeof item === "string" && item.length > 0)) {
    errors.push("matches 必须是非空的 bundle ID 字符串数组");
  }
  if (manifest.summary !== undefined && !isLocalizedText(manifest.summary)) {
    errors.push("summary 必须是非空的本地化字符串对象");
  }
  if (manifest.refreshInterval !== undefined
      && (typeof manifest.refreshInterval !== "number"
          || !Number.isFinite(manifest.refreshInterval)
          || manifest.refreshInterval <= 0
          || manifest.refreshInterval > 86400)) {
    errors.push("refreshInterval 必须是 (0, 86400] 内的有限数字");
  }
  if (manifest.renderScope !== undefined && manifest.renderScope !== null
      && !["app", "window"].includes(manifest.renderScope)) {
    errors.push("renderScope 必须是 app 或 window");
  }
  if (manifest.defaultEnabled !== undefined
      && typeof manifest.defaultEnabled !== "boolean") {
    errors.push("defaultEnabled 必须是 boolean");
  }
  const permissions = validatePermissions(manifest, errors, warnings);
  validateSettings(manifest.settings, errors);
  validateFSRoots(manifest, permissions, errors);
  return {
    ok: errors.length === 0,
    id,
    permissions,
    errors,
    warnings,
  };
}

function validatePermissions(manifest, errors, warnings) {
  if (!Array.isArray(manifest.permissions)) {
    errors.push("permissions 必须是数组");
    return [];
  }
  const seen = new Set();
  for (const permission of manifest.permissions) {
    if (typeof permission !== "string") {
      errors.push("permissions 中的每一项都必须是 string");
      continue;
    }
    if (seen.has(permission)) errors.push(`permissions 包含重复项：${permission}`);
    seen.add(permission);
    const known = allowedPermissions.has(permission) || /^appleScript:.+$/.test(permission);
    if (!known) errors.push(`未知权限：${permission}`);
    if (permission === "window.focus") {
      warnings.push("window.focus 当前仅可声明，宿主不会注入聚焦 API");
    }
    if (permission.startsWith("appleScript:")) {
      warnings.push(`${permission} 当前仅可声明，宿主不会注入 AppleScript API`);
    }
  }
  return manifest.permissions;
}

function validateFSRoots(manifest, permissions, errors) {
  const roots = manifest.fsRoots ?? [];
  if (!Array.isArray(roots)) {
    errors.push("fsRoots 必须是数组");
    return;
  }
  const hasFS = permissions.includes("fs.read");
  if (hasFS !== (roots.length > 0)) {
    errors.push("fs.read 权限与非空 fsRoots 必须同时出现");
  }
  const seen = new Set();
  roots.forEach((root, index) => {
    const where = `fsRoots[${index}]`;
    if (!isObject(root)) {
      errors.push(`${where} 必须是对象`);
      return;
    }
    if (typeof root.id !== "string" || !rootIDPattern.test(root.id)) {
      errors.push(`${where}.id 必须匹配 ^[A-Za-z0-9_-]+$`);
    } else if (seen.has(root.id)) {
      errors.push(`fsRoots id 重复：${root.id}`);
    } else {
      seen.add(root.id);
    }
    const pathIssue = lexicalFSPathIssue(root.path);
    if (pathIssue) errors.push(`${where}.path ${pathIssue}`);
    if (!isLocalizedText(root.summary)) {
      errors.push(`${where}.summary 必须是非空的本地化字符串对象`);
    }
  });
}

async function validateEntry(pluginDir, manifest, errors) {
  if (typeof manifest.entry !== "string" || !isSafeRelativePath(manifest.entry)) {
    errors.push("entry 必须是插件目录内的安全相对路径");
    return null;
  }
  const entryPath = path.resolve(pluginDir, manifest.entry);
  if (!isWithin(pluginDir, entryPath)) {
    errors.push("entry 越出插件目录");
    return null;
  }
  try {
    const info = await stat(entryPath);
    if (!info.isFile()) {
      errors.push("entry 不是普通文件");
      return null;
    }
    if (info.size > packageLimits.maxEntryBytes) {
      errors.push(`entry 超过 2 MiB：${info.size} bytes`);
      return null;
    }
    const realEntry = await realpath(entryPath);
    const realPluginDir = await realpath(pluginDir);
    if (!isWithin(realPluginDir, realEntry)) {
      errors.push("entry 经符号链接解析后越出插件目录");
      return null;
    }
    const source = await readFile(realEntry, "utf8");
    return { path: realEntry, source };
  } catch (error) {
    errors.push(`entry 不存在或不可读：${error.message}`);
    return null;
  }
}

async function validateResourceReferences(pluginDir, source, errors) {
  const candidates = new Set();
  const keyed = /\b(pluginAsset|asset|image)\s*:\s*(["'])([^"'\\\r\n]+)\2/g;
  for (const match of source.matchAll(keyed)) {
    const value = match[3];
    const trailing = source.slice(match.index + match[0].length);
    if (value.endsWith("/") || /^\s*\+/.test(trailing)) continue;
    if (value.includes("://")) {
      errors.push(`资源 ${match[1]} 不能使用网络 URL：${value}`);
    } else if (value.startsWith("./") || value.startsWith("assets/")
               || value.startsWith("../") || value.startsWith("/")
               || /\.[A-Za-z0-9]{2,8}$/.test(value)) {
      candidates.add(value);
    }
  }
  const literals = /(["'])((?:\.\/)?assets\/[^"'\\\r\n]+)\1/g;
  for (const match of source.matchAll(literals)) {
    const trailing = source.slice(match.index + match[0].length);
    if (!match[2].endsWith("/") && !/^\s*\+/.test(trailing)) candidates.add(match[2]);
  }

  for (const candidate of candidates) {
    if (!isSafeRelativePath(candidate)) {
      errors.push(`资源路径越出插件目录：${candidate}`);
      continue;
    }
    const target = path.resolve(pluginDir, candidate);
    if (!isWithin(pluginDir, target)) {
      errors.push(`资源路径越出插件目录：${candidate}`);
      continue;
    }
    try {
      const info = await stat(target);
      if (!info.isFile()) errors.push(`资源不是普通文件：${candidate}`);
      const realTarget = await realpath(target);
      const realPluginDir = await realpath(pluginDir);
      if (!isWithin(realPluginDir, realTarget)) {
        errors.push(`资源经符号链接解析后越出插件目录：${candidate}`);
      }
    } catch {
      errors.push(`资源文件不存在：${candidate}`);
    }
  }
}

async function validateLocales(pluginDir, errors) {
  const localeDir = path.join(pluginDir, "locales");
  let entries;
  try {
    entries = await readdir(localeDir, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT") return;
    errors.push(`locales 目录不可读：${error.message}`);
    return;
  }
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    const file = path.join(localeDir, entry.name);
    const value = await readJSON(file, `locales/${entry.name}`, errors);
    if (value === null) continue;
    if (!isObject(value) || !Object.values(value).every((item) => typeof item === "string")) {
      errors.push(`locales/${entry.name} 必须是 string 到 string 的对象`);
    }
  }
}

export async function validatePluginDirectory(inputDirectory) {
  const pluginDir = path.resolve(inputDirectory);
  const errors = [];
  const warnings = [];
  let manifest = null;
  try {
    await stat(pluginDir);
  } catch (error) {
    errors.push(`插件目录不存在或不可读：${error.message}`);
    return { ok: false, directory: pluginDir, id: null, errors, warnings };
  }
  const models = await validatePackageEntries(pluginDir, errors);
  await validateModels(models, errors);

  const manifestPath = path.join(pluginDir, "manifest.json");
  try {
    const manifestSize = (await stat(manifestPath)).size;
    if (manifestSize > packageLimits.maxManifestBytes) {
      errors.push(`manifest.json 超过 256 KiB：${manifestSize} bytes`);
    }
  } catch {
    // readJSON 会给出缺失或不可读的错误。
  }
  manifest = await readJSON(manifestPath, "manifest.json", errors);
  if (manifest !== null && !isObject(manifest)) {
    errors.push("manifest.json 顶层必须是对象");
    manifest = null;
  }

  let id = null;
  if (manifest) {
    const manifestValidation = validateManifest(manifest);
    errors.push(...manifestValidation.errors);
    warnings.push(...manifestValidation.warnings);
    id = manifestValidation.id;
    const entry = await validateEntry(pluginDir, manifest, errors);
    if (entry) await validateResourceReferences(pluginDir, entry.source, errors);
    await validateLocales(pluginDir, errors);
  }

  return {
    ok: errors.length === 0,
    directory: pluginDir,
    id,
    errors,
    warnings,
  };
}

export const validationConstants = Object.freeze({
  packageLimits,
  glbLimits,
  glbAllowedExtensions: Object.freeze([...glbAllowedExtensions]),
  secretFileNames: Object.freeze([...secretFileNames]),
});
