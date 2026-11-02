import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  access,
  mkdir,
  mkdtemp,
  rm,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(testDirectory, "..");

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
