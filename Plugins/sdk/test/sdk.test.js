import assert from "node:assert/strict";
import test from "node:test";
import { definePanelPlugin, definePlugin, ui } from "../src/index.js";

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

test("definePanelPlugin 与 definePlugin 使用相同的注册合同", () => {
  const previous = globalThis.__switchlyPlugin;
  const plugin = { render: () => [{ slot: "panel", node: ui.text({ value: "活动" }) }] };
  try {
    assert.equal(definePanelPlugin(plugin), plugin);
    assert.equal(globalThis.__switchlyPlugin, plugin);
    assert.throws(
      () => definePanelPlugin({}),
      /render/,
    );
  } finally {
    globalThis.__switchlyPlugin = previous;
  }
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

test("activity 面板 UI 构建器生成宿主 wire shape", () => {
  const bars = [
    { label: "Safari", value: 3_600 },
    { label: "Xcode", value: 5_400 },
  ];
  const children = [
    ui.image({
      source: { activitySnapshot: "A1B2C3D4-E5F6-4789-90AB-CDEF01234567" },
      size: "l",
      corner: "m",
    }),
  ];
  const segmented = ui.segmented({
    id: "dimension",
    options: ["hour", "day", "month"],
    selected: 1,
  });
  const dateRange = ui.dateRange({
    id: "range",
    from: 1_699_920_000,
    to: 1_700_006_400,
    label: "最近 1 天",
  });
  const barChart = ui.barChart(bars);
  const grid = ui.grid(children);

  assert.deepEqual(segmented, {
    id: "dimension",
    options: ["hour", "day", "month"],
    selected: 1,
    type: "segmented",
  });
  assert.deepEqual(dateRange, {
    id: "range",
    from: 1_699_920_000,
    to: 1_700_006_400,
    label: "最近 1 天",
    type: "dateRange",
  });
  assert.deepEqual(barChart, { items: bars, type: "barChart" });
  assert.deepEqual(grid, { children, type: "grid" });
  assert.deepEqual(children[0].source, {
    activitySnapshot: "A1B2C3D4-E5F6-4789-90AB-CDEF01234567",
  });

  bars.push({ label: "Terminal", value: 1_200 });
  children.push(ui.text({ value: "不应进入已构建节点" }));
  assert.equal(barChart.items.length, 2);
  assert.equal(grid.children.length, 1);
});

test("lineChart 复用 bar item wire shape，限制交由宿主解码器", () => {
  const points = Array.from({ length: 64 }, (_, index) => ({
    label: `点 ${index}`,
    value: index,
  }));
  const lineChart = ui.lineChart(points);

  assert.deepEqual(lineChart, { items: points, type: "lineChart" });
  assert.notStrictEqual(lineChart.items, points);
  points.push({ label: "迟到点", value: 64 });
  assert.equal(lineChart.items.length, 64);
  assert.deepEqual(lineChart.items[0], { label: "点 0", value: 0 });
});

test("lineChart 附加序列保留图例及独立数组", () => {
  const items = [{ label: "09:00", value: 60 }];
  const series = [{ label: "编辑器", items: [{ label: "09:00", value: 40 }] }];
  const node = ui.lineChart(items, { label: "汇总", series });
  assert.deepEqual(node, { type: "lineChart", label: "汇总", items, series });
  series[0].items.push({ label: "10:00", value: 0 });
  assert.equal(node.series[0].items.length, 1);
  assert.notStrictEqual(node.series, series);
});

test("lineChart 按 ctx.uiFeatures 协商，缺失时回退到已有节点", () => {
  const previous = globalThis.__switchlyPlugin;
  const items = [{ label: "Safari", value: 3_600 }];
  const plugin = definePanelPlugin({
    render(ctx) {
      const node = ctx.uiFeatures?.lineChart === true
        ? ui.lineChart(items)
        : ui.barChart(items);
      return [{ slot: "panel", node }];
    },
  });
  try {
    assert.equal(plugin.render({ uiFeatures: { lineChart: true } })[0].node.type, "lineChart");
    assert.equal(plugin.render({ uiFeatures: { lineChart: false } })[0].node.type, "barChart");
    assert.equal(plugin.render({})[0].node.type, "barChart");
  } finally {
    globalThis.__switchlyPlugin = previous;
  }
});

test("timeline 保留 timestamp/content wire shape 且只复制数组", () => {
  const items = [
    { timestamp: 1_699_920_000, content: ui.text({ value: "Safari" }) },
    { timestamp: 1_700_006_400, content: ui.text({ value: "Xcode" }) },
  ];
  const timeline = ui.timeline(items);

  assert.deepEqual(timeline, { items, type: "timeline" });
  assert.notStrictEqual(timeline.items, items);
  items.push({ timestamp: 1_700_092_800, content: ui.text({ value: "迟到项" }) });
  assert.equal(timeline.items.length, 2);
  assert.deepEqual(timeline.items[0], {
    timestamp: 1_699_920_000,
    content: { value: "Safari", type: "text" },
  });
});

test("timeline 按既有 ctx.uiFeatures 协商，缺失时回退到同顺序纵向内容列表", () => {
  const previous = globalThis.__switchlyPlugin;
  const items = [
    { timestamp: 1_699_920_000, content: ui.text({ value: "Safari" }) },
    { timestamp: 1_700_006_400, content: ui.text({ value: "Xcode" }) },
  ];
  const plugin = definePanelPlugin({
    render(ctx) {
      const node = ctx.uiFeatures?.timeline === true
        ? ui.timeline(items)
        : ui.vstack(items.map((item) => item.content));
      return [{ slot: "panel", node }];
    },
  });
  try {
    assert.equal(plugin.render({ uiFeatures: { scene3d: false, timeline: true } })[0].node.type, "timeline");
    const fallback = plugin.render({ uiFeatures: { scene3d: false, timeline: false } })[0].node;
    assert.equal(fallback.type, "vstack");
    assert.deepEqual(fallback.children, items.map((item) => item.content));
    assert.equal(plugin.render({})[0].node.type, "vstack");
  } finally {
    globalThis.__switchlyPlugin = previous;
  }
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
