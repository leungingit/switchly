import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

test("制备契约时并行读者始终读到完整的旧版本或新版本", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-contract-readers-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cli = path.join(root, "Plugins", "cli");
  const api = path.join(root, "Plugins", "api");
  const script = path.join(cli, "scripts", "prepare-contract.mjs");
  const contract = path.join(cli, "contract");
  await mkdir(path.dirname(script), { recursive: true });
  await mkdir(api, { recursive: true });
  await mkdir(contract);
  await copyFile(fileURLToPath(new URL("../scripts/prepare-contract.mjs", import.meta.url)), script);
  const names = ["preview-activity-fixture.schema.json", "capabilities.json", "manifest.schema.json", "preview-scenario.schema.json",
    "preview-media-fixture.schema.json", "preview-weather-fixture.schema.json", "preview-fs-fixture.schema.json"];
  const contents = new Map(names.map((name) => [name, JSON.stringify({ name, data: "x".repeat(256 * 1024) })]));
  for (const [name, content] of contents) {
    await writeFile(path.join(api, name), content);
    await writeFile(path.join(contract, name), content);
  }
  const writer = spawn(process.execPath, ["--input-type=module", "-e", `
    import { writeFile } from "node:fs/promises";
    for (let i = 0; i < 40; i++) {
      await writeFile(${JSON.stringify(path.join(api, names[0]))}, JSON.stringify({ name: ${JSON.stringify(names[0])}, data: (i % 2 ? "y" : "x").repeat(256 * 1024) }));
      await import(${JSON.stringify(pathToFileURL(script).href)} + "?iteration=" + i);
    }
  `], { stdio: ["ignore", "ignore", "pipe"] });
  t.after(() => { if (writer.exitCode === null) writer.kill(); });
  let diagnostic = "";
  writer.stderr.on("data", (chunk) => { diagnostic += chunk; });
  let running = true;
  writer.once("exit", () => { running = false; });
  const completed = once(writer, "close");
  let incomplete = false;
  let reads = 0;
  const changed = JSON.stringify({ name: names[0], data: "y".repeat(256 * 1024) });
  while (running) {
    for (const [name, content] of contents) {
      const observed = await readFile(path.join(contract, name), "utf8");
      if (observed !== content && !(name === names[0] && observed === changed)) incomplete = true;
      reads += 1;
    }
  }
  const [code] = await completed;
  assert.equal(code, 0, diagnostic);
  assert(reads > 0);
  assert.equal(incomplete, false, "读者不应看到 copyFile 截断后的空文件或部分内容");
});
