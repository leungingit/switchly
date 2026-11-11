import { access, copyFile, mkdir, readFile } from "node:fs/promises";
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
  try {
    // npm pack 可与契约读取并行；相同内容不再截断重写已准备的文件。
    try {
      if ((await readFile(source)).equals(await readFile(destination))) continue;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await copyFile(source, destination);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    // 已发布包包含 contract；再次从包内执行 prepack 时无需仓库源文件。
    await access(destination);
  }
}
