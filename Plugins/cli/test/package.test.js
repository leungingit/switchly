import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  access,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  utimes,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(testDirectory, "..");

test("契约准备复用相同文件且仍更新变化的来源", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-contract-prepare-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = path.join(root, "Plugins/api");
  const target = path.join(root, "Plugins/cli/contract");
  const script = path.join(root, "Plugins/cli/scripts/prepare-contract.mjs");
  await mkdir(source, { recursive: true });
  await mkdir(path.dirname(script), { recursive: true });
  await copyFile(path.join(packageDirectory, "scripts/prepare-contract.mjs"), script);
  const files = ["preview-activity-fixture.schema.json", "capabilities.json", "manifest.schema.json", "preview-scenario.schema.json",
    "preview-media-fixture.schema.json", "preview-weather-fixture.schema.json", "preview-fs-fixture.schema.json"];
  for (const name of files) await writeFile(path.join(source, name), JSON.stringify({ name }));
  execFileSync(process.execPath, [script]);
  const timestamp = new Date("2000-01-01T00:00:00Z");
  for (const name of files) await utimes(path.join(target, name), timestamp, timestamp);
  execFileSync(process.execPath, [script]);
  for (const name of files) {
    assert.equal((await stat(path.join(target, name))).mtimeMs, timestamp.getTime());
    assert.deepEqual(await readFile(path.join(target, name)), await readFile(path.join(source, name)));
  }
  await writeFile(path.join(source, "capabilities.json"), '{"updated":true}');
  execFileSync(process.execPath, [script]);
  assert.equal(await readFile(path.join(target, "capabilities.json"), "utf8"), '{"updated":true}');
});

test("npm pack 后的 CLI 自包含 contract 且可执行 create", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-plugin-pack-"));
  t.after(() => rm(root, { recursive: true, force: true }));

  const packed = spawnSync(
    "npm",
    ["pack", packageDirectory, "--pack-destination", root, "--json"],
    { cwd: root, encoding: "utf8" },
  );
  assert.equal(packed.status, 0, packed.stderr);
  const filename = JSON.parse(packed.stdout)[0].filename;
  const tarball = path.join(root, filename);
  const extracted = path.join(root, "extracted");
  await mkdir(extracted);
  const unpacked = spawnSync("tar", ["-xzf", tarball, "-C", extracted], {
    encoding: "utf8",
  });
  assert.equal(unpacked.status, 0, unpacked.stderr);

  const packedPackage = path.join(extracted, "package");
  await access(path.join(packedPackage, "contract", "capabilities.json"));
  await access(path.join(packedPackage, "contract", "manifest.schema.json"));
  await access(path.join(packedPackage, "contract", "preview-scenario.schema.json"));
  await access(path.join(packedPackage, "contract", "preview-media-fixture.schema.json"));
  await access(path.join(packedPackage, "contract", "preview-weather-fixture.schema.json"));
  await access(path.join(packedPackage, "contract", "preview-fs-fixture.schema.json"));
  const publicValidator = await import(pathToFileURL(
    path.join(packedPackage, "src", "validate.js"),
  ).href);
  const manifest = {
    id: "com.example.packed",
    name: { en: "Packed" },
    version: "1",
    apiVersion: 2,
    matches: ["com.example.target"],
    permissions: [],
    entry: "main.js",
    settings: [{ key: "enabled", title: { en: "Enabled" }, default: true }],
  };
  assert.equal(publicValidator.validateManifest(manifest).ok, true);
  manifest.settings = [{ key: "unsupported", type: "string", title: { en: "Unsupported" }, default: "x" }];
  assert.equal(publicValidator.validateManifest(manifest).ok, false);
  const cli = path.join(packedPackage, "bin", "switchly-plugin.js");
  const described = execFileSync(process.execPath, [cli, "api", "describe", "--json"], {
    cwd: root,
    encoding: "utf8",
  });
  const capabilities = JSON.parse(described);
  const storage = capabilities.features.find((feature) => feature.id === "ctx.storage");
  assert.equal(storage.asynchronous, true);

  const plugin = path.join(root, "generated");
  const created = execFileSync(process.execPath, [
    cli,
    "create",
    plugin,
    "--id",
    "com.example.packed",
    "--json",
  ], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(JSON.parse(created).validation.ok, true);
});
