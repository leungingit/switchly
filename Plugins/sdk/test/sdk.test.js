import assert from "node:assert/strict";
import test from "node:test";
import { definePlugin, ui } from "../src/index.js";

test("definePlugin 注册宿主约定的全局对象", () => {
  const previous = globalThis.__switchlyPlugin;
  const plugin = { render: () => [] };
  try {
    assert.equal(definePlugin(plugin), plugin);
    assert.equal(globalThis.__switchlyPlugin, plugin);
  } finally {
    globalThis.__switchlyPlugin = previous;
  }
});

test("definePlugin 拒绝缺少 render 的定义", () => {
  assert.throws(
    () => definePlugin({}),
    /render/,
  );
});

test("UI 构建器生成宿主可解码的节点", () => {
  const button = ui.button({
    id: "toggle",
    symbol: "play.fill",
    label: "播放",
  });
  const root = ui.surface([
    ui.vstack([button, ui.spacer()], { spacing: "xs", align: "center" }),
  ], { material: "glass" });

  assert.deepEqual(button, {
    type: "button",
    id: "toggle",
    symbol: "play.fill",
    label: "播放",
  });
  assert.equal(root.type, "surface");
  assert.equal(root.material, "glass");
  assert.equal(root.children[0].type, "vstack");
  assert.equal(root.children[0].spacing, "xs");
});

test("wheel 与 scene 构建器保留完整载荷", () => {
  const wheel = ui.wheel([
    ui.spacer(),
    ui.spacer(),
    ui.spacer(),
    ui.spacer(),
    ui.badge({ value: "5", tone: "accent" }),
  ]);
  const scene = ui.scene({
    key: "demo",
    epoch: 1_700_000_000,
    width: 320,
    height: 180,
    layers: [{ kind: "rect", fill: "#112233" }],
  });

  assert.equal(wheel.children.length, 5);
  assert.equal(scene.type, "scene");
  assert.equal(scene.layers[0].kind, "rect");
});
