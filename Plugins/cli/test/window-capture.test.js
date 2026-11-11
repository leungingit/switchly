import assert from "node:assert/strict";
import test from "node:test";
import { validateManifest } from "../src/validate.js";

test("窗口截图权限与范围可声明，旧清单兼容，未知范围拒绝", () => {
  const base = { id: "com.test.capture", name: { en: "Capture", "zh-Hans": "截图" }, version: "1", apiVersion: 2,
    matches: ["*"], permissions: ["window.capture"], entry: "main.js" };
  for (const renderScope of [undefined, null, "app", "window"]) {
    assert.deepEqual(validateManifest({ ...base, renderScope }).errors, []);
  }
  for (const renderScope of ["desktop", 2, true]) {
    assert(validateManifest({ ...base, renderScope }).errors.some(error => error.includes("renderScope")));
  }
});
