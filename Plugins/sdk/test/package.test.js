import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  access,
  cp,
  mkdir,
  mkdtemp,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(testDirectory, "..");

async function packSDK(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "switchly-sdk-pack-"));
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
  await access(path.join(packedPackage, "index.d.ts"));
  return { root, packedPackage };
}

test("npm pack 后的 SDK 可直接引用运行时代码且包含类型入口", async (t) => {
  const { packedPackage } = await packSDK(t);
  const moduleURL = pathToFileURL(path.join(packedPackage, "src", "index.js"));
  const sdk = await import(moduleURL.href);
  const plugin = sdk.definePlugin({
    render: (ctx) => [{
      slot: "titleAccessory",
      node: sdk.ui.badge({ value: String(ctx.storage) }),
    }],
  });
  assert.equal(globalThis.__switchlyPlugin, plugin);
});

test("npm pack 后的 SDK types 路径可由 tsc 解析", async (t) => {
  const tscVersion = spawnSync("tsc", ["--version"], { encoding: "utf8" });
  if (tscVersion.error?.code === "ENOENT") {
    t.skip("本机没有 tsc，已跳过打包后类型解析验证");
    return;
  }
  assert.equal(tscVersion.status, 0, tscVersion.stderr);
  const { root, packedPackage } = await packSDK(t);
  const nodeModules = path.join(root, "node_modules", "@switchly");
  const installedPackage = path.join(nodeModules, "plugin-sdk");
  await mkdir(nodeModules, { recursive: true });
  await cp(packedPackage, installedPackage, { recursive: true });
  await writeFile(path.join(root, "consumer.mts"), `
import {
  definePanelPlugin,
  definePlugin,
  ui,
  type ActivitySnapshotItem,
  type PluginBarItem,
  type PluginContext,
  type PluginDefinition,
  type PluginLineChartNode,
  type PluginManifest,
  type PluginNode,
  type PluginPanelContext,
  type PluginTimelineItem,
  type PluginTimelineNode,
  type PluginSlotContent,
  type PluginScene,
  type PluginUIFeatures,
} from "@switchly/plugin-sdk";

const manifest: PluginManifest = {
  id: "com.example.types",
  name: { en: "Types" },
  version: "1",
  apiVersion: 2,
  matches: ["com.example.app"],
  permissions: ["activity.read", "activity.snapshots"],
  entry: "main.js",
  surfaces: ["dockPreview", "panel"],
};

const scene: PluginScene = {
  key: "types",
  epoch: 0,
  width: 100,
  height: 100,
  layers: [],
};

definePlugin({
  async render(ctx: PluginContext) {
    const value = await ctx.storage.get("key");
    await ctx.storage.set("key", value);
    const bundleID: string = ctx.app.bundleID;
    const title: string = ctx.window.title;
    const surface: "dockPreview" | undefined = ctx.surface;
    const panelSupported: boolean | undefined = ctx.uiFeatures?.panel;
    const activitySupported: boolean | undefined = ctx.uiFeatures?.activity;
    const lineChartSupported: boolean | undefined = ctx.uiFeatures?.lineChart;
    const timelineSupported: boolean | undefined = ctx.uiFeatures?.timeline;
    if (ctx.activity) {
      const summary = await ctx.activity.summary({
        from: 1_699_920_000,
        to: 1_700_006_400,
        groupBy: "day",
        timeZone: "Asia/Singapore",
      });
      const availableFrom: number | null = summary.availableFrom;
      const recording: boolean = summary.recording;
      const screenshotsEnabled: boolean = summary.screenshotsEnabled;
      const revision: number = summary.revision;
      for (const item of summary.items) {
        const name: string = item.name;
        const bucketStart: number | undefined = item.bucketStart;
      }

      const sessions = await ctx.activity.sessions({
        from: 1_699_920_000,
        to: 1_700_006_400,
        limit: 100,
        cursor: null,
        bundleID,
      });
      const nextCursor: string | null = sessions.nextCursor;
      for (const item of sessions.items) {
        const id: string = item.id;
        const appName: string = item.appName;
        const endReason = item.endReason;
      }

      if (ctx.activity.snapshots) {
        const snapshots = await ctx.activity.snapshots({
          from: 1_699_920_000,
          to: 1_700_006_400,
          limit: 6,
        });
        for (const item of snapshots.items) {
          const ref: string = item.ref;
          const capturedAt: number = item.capturedAt;
          const sessionID: string | undefined = item.sessionID;
          const snapshot: ActivitySnapshotItem = item;
          void [sessionID, snapshot];
        }
      }
      void [availableFrom, recording, screenshotsEnabled, revision, nextCursor, title, surface,
        panelSupported, activitySupported, lineChartSupported, timelineSupported];
    }
    return [{ slot: "center", node: ui.scene(scene) }];
  },
});

const points: readonly PluginBarItem[] = [
  { label: "Safari", value: 3_600 },
  { label: "Xcode", value: 5_400 },
];
const lineChart: PluginLineChartNode = ui.lineChart(points);
const appChart: PluginLineChartNode = ui.lineChart(points, {
  label: "Total", series: [{ label: "Editor", items: points }],
});
const multiLineNegotiation: PluginUIFeatures = { scene3d: false, lineChartSeries: true };
const timelineItems: readonly PluginTimelineItem[] = [
  { timestamp: 1_699_920_000, content: ui.text({ value: "Safari" }) },
  { timestamp: 1_700_006_400, content: ui.text({ value: "Xcode" }) },
];
const timeline: PluginTimelineNode = ui.timeline(timelineItems);
const negotiation: PluginUIFeatures = { scene3d: true, lineChart: true, timeline: true };

const panelNodes: readonly PluginNode[] = [
  ui.segmented({ id: "dimension", options: ["hour", "day", "month"], selected: 2 }),
  ui.dateRange({ id: "range", from: 1_699_920_000, to: 1_700_006_400, label: "最近 1 天" }),
  ui.barChart([{ label: "Safari", value: 3_600 }]),
  lineChart,
  appChart,
  timeline,
  ui.grid([
    ui.image({
      source: { activitySnapshot: "A1B2C3D4-E5F6-4789-90AB-CDEF01234567" },
    }),
  ]),
];
const panelOutput: readonly PluginSlotContent[] = [{ slot: "panel", node: panelNodes[0]! }];

const panelDefinition: PluginDefinition<PluginPanelContext> = {
  prepare(ctx) {
    const bundleID: string = ctx.app.bundleID;
    const title: string = ctx.window.title;
    const timelineSupported: boolean | undefined = ctx.uiFeatures?.timeline;
    void [bundleID, title, timelineSupported];
    return panelOutput;
  },
  render(ctx) {
    const app: null = ctx.app;
    const window: null = ctx.window;
    const surface: "panel" = ctx.surface;
    const lineChartSupported: boolean | undefined = ctx.uiFeatures?.lineChart;
    const timelineSupported: boolean | undefined = ctx.uiFeatures?.timeline;
    void [app, window, surface, lineChartSupported, timelineSupported];
    return panelOutput;
  },
};
const panelPlugin = definePanelPlugin(panelDefinition);
const returnedPanelPlugin: PluginDefinition<PluginPanelContext> = panelPlugin;

void panelNodes;
void returnedPanelPlugin;
void [manifest, negotiation];
`);
  const tsc = spawnSync("tsc", [
    "--noEmit",
    "--strict",
    "--target",
    "ES2022",
    "--module",
    "NodeNext",
    "--moduleResolution",
    "NodeNext",
    "consumer.mts",
  ], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(tsc.status, 0, `${tsc.stdout}\n${tsc.stderr}`);
});
