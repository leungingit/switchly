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

test("scene3d 构建器保留完整载荷与 fallback", () => {
  const fallback = ui.vstack([ui.text({ value: "2D" })]);
  const node = ui.scene3d({
    key: "ipod",
    asset: "assets/ipod.glb",
    fit: "contain",
    camera: { yaw: 12, pitch: -8 },
    rotate: { horizontal: true, vertical: true, pitchMin: -55, pitchMax: 55 },
    surfaces: [{ node: "mesh_screen", size: [480, 320], content: fallback }],
    hits: [{ node: "mesh_wheel_play", id: "play", label: "播放", value: null }],
    fallback,
  });

  assert.equal(node.type, "scene3d");
  assert.equal(node.asset, "assets/ipod.glb");
  assert.deepEqual(node.surfaces[0].size, [480, 320]);
  assert.equal(node.surfaces[0].content.children[0].type, "text");
  assert.equal(node.hits[0].id, "play");
  assert.equal(node.fallback.type, "vstack");
});
