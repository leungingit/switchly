import { randomUUID } from "node:crypto";
import { access, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const repositoryRoot = path.resolve(packageDirectory, "../..");
const contractDirectory = path.join(packageDirectory, "contract");
const files = [
  "capabilities.json",
  "manifest.schema.json",
  "preview-scenario.schema.json",
  "preview-media-fixture.schema.json",
  "preview-weather-fixture.schema.json",
  "preview-fs-fixture.schema.json",
];

await mkdir(contractDirectory, { recursive: true });
for (const file of files) {
  const source = path.join(repositoryRoot, "Plugins/api", file);
  const destination = path.join(contractDirectory, file);
  let contents;
  try {
    contents = await readFile(source);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    // 已发布包包含 contract；再次从包内执行 prepack 时无需仓库源文件。
    await access(destination);
    continue;
  }
  try {
    if (contents.equals(await readFile(destination))) continue;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  // prepack 可与 CLI 读者并行；不截断已发布的契约文件。
  const staged = path.join(contractDirectory, `.${file}.${randomUUID()}.tmp`);
  try {
    await writeFile(staged, contents, { flag: "wx" });
    await rename(staged, destination);
  } finally {
    await rm(staged, { force: true });
  }
}
