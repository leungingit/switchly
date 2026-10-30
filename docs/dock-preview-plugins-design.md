# Dock 预览插件系统 — 方案调研与设计（草案）

> 状态：Phase 1 运行时已实现；Phase 0 的 AppleScript 验证已完成（见 §6 R1）；内置 Music 插件（`Resources/Plugins/com.switchly.music-controls/`）、`PluginOverlayView` 渲染、Music 媒体桥已接入 Dock 预览，真机悬停验收待完成（R2）。封面（宿主读取，插件拿不到像素）、曲名滚动、插件授权（`AppSettings.pluginGrants` + 设置 → 权限 → 插件）已实现；SDK 尚未开始。日期：2026-10-23。分支：`feat/dock-preview-plugins`。
> 本文的结论尚未经原型验证，标注「待验证」的条目需在 Phase 0 原型中实测后更新。

## 1. 目标与非目标

**目标**

- 允许第三方用 TypeScript / JavaScript 编写插件，按目标应用（bundle ID）为 Dock 预览中的窗口卡片叠加自定义控件，例如音乐应用的「播放/暂停、上一首、下一首、喜欢」。
- 插件开发体验接近前端生态：npm 发布 SDK、类型提示、脚手架、本地调试。
- 保持 Switchly 现有约束：完全本地、无网络、无遥测；视觉复用 `DesignTokens` / `GlassEffect`；macOS 12 可用。

**非目标（初期）**

- 不提供在线插件市场或自动更新（涉及网络，与 [PRIVACY_POLICY.md](../PRIVACY_POLICY.md) 冲突，需单独决策）。
- 不允许插件渲染任意 HTML / 自绘像素。
- 不覆盖预览网格、Workspace 栏，仅 Dock 预览（后续可扩展）。

## 2. 候选方案对比

| 方案 | 运行方式 | 生态 | 体积 / 性能 | 安全与隐私 | 视觉一致性 | 结论 |
|---|---|---|---|---|---|---|
| **A. 内嵌 JavaScriptCore + 声明式 UI** | 系统 JSC 执行打包后的 JS；插件返回 UI 描述，由 SwiftUI 渲染 | TS + 纯 JS npm 包；无 Node 内置模块 | 零新增依赖；每插件一个 `JSContext`，毫秒级启动 | 默认无网络 / 文件能力，按 manifest 授权 | 完全复用原生令牌与材质 | **采用** |
| B. Node 子进程 + JSON-RPC | 打包 Node 运行时，stdio 通信 | 完整 npm | +40MB 以上，进程管理复杂 | 插件可任意联网 / 读文件 | 原生渲染，可一致 | 不采用：违背本地隐私边界、体积大 |
| C. WKWebView 叠层 | 每卡片一个网页视图 | 完整前端 | 多卡片时内存与首帧开销高 | 需额外屏蔽网络 | 材质、透明度难统一 | 不采用 |
| D. 任意可执行插件 | 外部二进制 + stdio | 任意语言 | 取决于插件 | 签名、公证、权限最难控 | 原生渲染 | 不采用 |

**裁决 D01**：采用方案 A。依据：零依赖、符合「完全本地」承诺、可做能力白名单、视觉由宿主统一。被取代条件：若 Phase 0 证明 JSC 在主流插件场景下性能或能力不足，再评估 B。

## 3. 方案 A 详细设计

### 3.1 总体架构

```
┌──────────── Switchly (Swift) ─────────────────────────────┐
│ DockPreviewView ── PluginOverlayView (SwiftUI 渲染 UI 树)   │
│        ▲ 渲染结果 / 用户动作                                  │
│ DockPreviewViewModel ── PluginHost (protocol PluginHosting) │
│                            │                                │
│      PluginRegistry ─ PluginRuntime(每插件 JSContext, 私有队列)│
│                            │  受控能力桥 (Capability Bridges) │
│      MediaBridge · AppleScriptBridge · MediaKeyBridge ·     │
│      WindowInfoBridge · StorageBridge · LogBridge           │
└────────────────────────────────────────────────────────────┘
          ▲ 加载
   ~/Library/Application Support/Switchly/Plugins/<id>/
       manifest.json + main.js (由 SDK 打包产出)
```

分层遵循 [AGENTS.md](../AGENTS.md) §3：

- `Services/Plugins/`：`PluginRegistry`、`PluginRuntime`、各 Bridge，均以 `protocol` 定义并注入。
- `Models/Plugins/`：`PluginManifest`、`PluginUINode`（UI 树）、`PluginCapability` 枚举。
- `ViewModels/`：Dock 预览 ViewModel 持有插件渲染状态，负责节流与取消。
- `Views/`：`PluginOverlayView` 只负责把 `PluginUINode` 渲染成原生控件。

### 3.2 插件包格式

```
com.example.music-controls/
├── manifest.json
├── main.js          # 单文件 bundle（esbuild 输出，IIFE / ESM 皆可，宿主约定一种）
└── icon.png         # 可选，设置页展示
```

`summary` 可选，用于设置页插件名后「?」的悬浮说明；缺省时只列权限。`manifest.json`：

```json
{
  "id": "com.example.music-controls",
  "name": { "en": "Music Controls", "zh-Hans": "音乐控制" },
  "summary": { "en": "Playback, Love and click-wheel controls for Apple Music.",
               "zh-Hans": "Apple Music 的播放、喜欢与点按转盘控件。" },
  "version": "0.1.0",
  "apiVersion": 1,
  "matches": ["com.apple.Music", "com.spotify.client"],
  "permissions": ["media.nowPlaying", "media.control", "appleScript:com.apple.Music"],
  "entry": "main.js"
}
```

- `apiVersion`：宿主支持范围外的插件拒绝加载并在设置页提示。
- `permissions`：未声明的能力在 JS 中不注入（不存在即无法调用），而非运行时拒绝。
- `appleScript:<bundleID>` 只允许调用宿主预置的脚本模板，不接受任意脚本字符串。

### 3.3 运行时（PluginRuntime）

- 每个插件一个 `JSVirtualMachine` + `JSContext`，在插件私有串行队列执行；JSC 对象不跨队列使用。
- 注入最小全局：`console`（→ `AppLogger`，带 `plugin=<id>`）、`setTimeout/clearTimeout`（宿主实现，随插件卸载清除）、`Promise`（JSC 原生）、SDK 所需的 `__switchly` 桥对象。
- **不注入**：`fetch`、`XMLHttpRequest`、文件系统、进程、`eval` 外部源加载。
- 超时：单次 `render` / `onAction` 默认 200ms 软超时；超时则丢弃结果并记日志，连续 N 次超时自动停用插件并在设置页提示。（数值待验证）
- 异常：捕获 `JSContext.exceptionHandler`，记录 `plugin=<id> phase=render error=...`，卡片回落为无叠层。
- 生命周期：Dock 预览出现 → 匹配插件 `mount`；面板关闭 / 切换应用 → `unmount`，取消定时器与订阅。重复 mount/unmount 必须安全。

### 3.4 插件 API 形态（JS 侧）

```ts
import { definePlugin, ui } from "@switchly/plugin-sdk";

export default definePlugin({
  async render(ctx) {
    const np = await ctx.media.nowPlaying();          // 需 media.nowPlaying
    if (!np) return null;                               // 无叠层
    return ui.bar([
      ui.button({ id: "prev", symbol: "backward.fill", label: ctx.t("Previous") }),
      ui.button({ id: "toggle", symbol: np.playing ? "pause.fill" : "play.fill",
                  label: ctx.t(np.playing ? "Pause" : "Play") }),
      ui.button({ id: "next", symbol: "forward.fill", label: ctx.t("Next") }),
      ui.button({ id: "like", symbol: np.liked ? "heart.fill" : "heart",
                  label: ctx.t("Like"), enabled: np.canLike }),
    ], { title: np.title, subtitle: np.artist });
  },
  async onAction(ctx, id) {
    if (id === "toggle") await ctx.media.togglePlayPause();
    if (id === "next") await ctx.media.next();
    if (id === "prev") await ctx.media.previous();
    if (id === "like") await ctx.media.setLiked(true);
    ctx.invalidate();                                   // 请求重新 render
  },
});
```

- `ctx` 每次调用都是只读快照：`ctx.app`（bundleID、pid、name）、`ctx.window`（windowID、标题摘要；无窗口时 windowID 为 0。「是否最小化」待 `WindowInfo` 提供后再加）。
- 状态刷新由宿主驱动：预览可见时按插件声明的 `refreshInterval`（下限 1s）或 `ctx.invalidate()` 重绘；不可见时零调用。

### 3.5 声明式 UI 与渲染

插件**不直接绘制像素**，而是描述一棵组件树（纯 JSON），宿主做 schema 校验后用 SwiftUI 绘制。这样播放按钮、进度条、封面等界面都能表达，同时保证材质、主题、无障碍与 Switchly 一致，也避免第三方代码拿到绘图上下文。

#### 3.5.1 挂载位置（slot）

插件通过 `render` 返回 `{ slot, node }`，一个插件可返回多个 slot：

| slot | 位置 | 尺寸约束 | 典型用途 |
|---|---|---|---|
| `bottomBar` | 卡片缩略图底部浮层 | 高 ≤ 卡片 30%，宽同卡片 | 播放控制条 |
| `center` | 缩略图中央，悬停时显示 | ≤ 卡片 50% × 50% | 大号播放 / 暂停按钮 |
| `topTrailing` | 右上角 | ≤ 24pt 方形 | 状态角标 |
| `titleAccessory` | 卡片标题行右侧 | 高同标题行 | 小图标、计数 |

#### 3.5.2 组件集（apiVersion 1）

| 类别 | 组件 | 主要属性 | 说明 |
|---|---|---|---|
| 布局 | `hstack` / `vstack` / `zstack` | `children`, `spacing: "xs"\|"s"\|"m"`, `align` | 间距取 `DesignTokens` 档位 |
| 布局 | `spacer` | — | 弹性占位 |
| 容器 | `surface` | `children`, `material: "glass"\|"plain"` | 宿主材质背景，复用 `GlassEffect` |
| 交互 | `button` | `id`, `symbol`, `label`, `size: "s"\|"m"\|"l"`, `variant: "plain"\|"prominent"`, `enabled`, `selected` | SF Symbol 图标按钮；悬停 / 按下 / 焦点 / 禁用态由宿主绘制 |
| 交互 | `toggle` | `id`, `symbolOn`, `symbolOff`, `isOn`, `label` | 如「喜欢」心形 |
| 交互 | `slider` | `id`, `value: 0...1`, `label`, `step?` | 进度拖动 / 音量；拖动结束才回调 `onAction(id, value)` |
| 展示 | `text` | `value`, `style: "title"\|"body"\|"caption"`, `lines?` | 超长截断 |
| 展示 | `progress` | `value: 0...1`, `style: "linear"\|"circular"` | 只读进度 |
| 展示 | `image` | `source: {symbol} \| {pluginAsset} \| {artwork}`, `size`, `corner: "s"\|"m"` | `artwork` 由宿主从媒体桥取得封面，插件拿不到原始像素 |
| 展示 | `badge` | `value`, `tone: "neutral"\|"accent"\|"warning"` | 语义色，不接受自定义颜色 |
| 展示 | `marquee` | `value` | 长歌名滚动；减少动态效果时退化为截断 |

#### 3.5.3 音乐控制示例

```ts
render: async (ctx) => {
  const np = await ctx.media.nowPlaying();
  if (!np) return [];
  return [
    { slot: "center", node: ui.button({ id: "toggle", size: "l", variant: "prominent",
        symbol: np.playing ? "pause.fill" : "play.fill", label: ctx.t(np.playing ? "Pause" : "Play") }) },
    { slot: "bottomBar", node: ui.surface({ material: "glass", children: [
        ui.hstack({ spacing: "s", children: [
          ui.image({ source: { artwork: true }, size: "s", corner: "s" }),
          ui.vstack({ children: [ ui.marquee({ value: np.title }), ui.text({ value: np.artist, style: "caption" }) ] }),
          ui.spacer(),
          ui.button({ id: "prev", symbol: "backward.fill", label: ctx.t("Previous") }),
          ui.button({ id: "next", symbol: "forward.fill", label: ctx.t("Next") }),
          ui.toggle({ id: "like", symbolOn: "heart.fill", symbolOff: "heart", isOn: np.liked, label: ctx.t("Like") }),
        ] }),
        ui.slider({ id: "seek", value: np.progress, label: ctx.t("Position") }),
      ] }) },
  ];
}
```

#### 3.5.4 交互与刷新

- 按钮状态（悬停、按下、焦点）完全由宿主本地绘制，不往返 JS，保证点击手感。
- 点击后宿主可先做**乐观更新**（如 `toggle` 立即翻转），再调用 `onAction`；失败时回滚并记日志。
- 进度条等连续变化：插件返回 `progress` 加 `rate`（每秒增量），由宿主本地插值动画，避免每秒高频调用 JS。

#### 3.5.5 为什么首期不开放自由绘制

| 选项 | 结论 |
|---|---|
| Canvas 风格的 2D 绘图 API | 暂不提供：无法保证主题 / 玻璃 / 无障碍一致，且每帧跨 JS 桥开销大 |
| 自定义 SVG / 位图 | 二期评估：仅允许插件包内静态资源（`pluginAsset`），宿主负责着色为单色模板 |
| WebView | 不提供（见 §2 方案 C） |

渲染约束：

- 尺寸、圆角、间距、材质只取 `DesignTokens` / `GlassEffect`，插件不能传颜色值或像素尺寸（`style` 仅限预定义枚举）。
- 叠层不超过卡片高度的约 30%，不遮挡标题；点击按钮不触发切窗（需在 `DockPreviewPanel` 的命中测试中隔离，待验证）。
- 键盘：按钮可聚焦，有焦点反馈；尊重「减少动态效果」；浅色 / 深色 / 玻璃开关全覆盖。
- 文案：插件自带 `locales/en.json`、`locales/zh-Hans.json`，经 `ctx.t()` 取用。

### 3.6 安全与隐私

- 插件安装 = 用户手动放入目录或在设置页「从文件夹安装」；首次启用展示 manifest 权限清单，用户确认后生效。
- 权限按插件持久化在 `AppSettings`（新增可选字段，`decodeIfPresent` 默认空）。
- 不提供网络能力；不提供截图像素数据；窗口标题仅提供摘要/截断形式（与日志脱敏原则一致）。
- 系统级权限（自动化 / Apple Events）由宿主申请，Info.plist 需新增 `NSAppleEventsUsageDescription`（变更走 `project.yml`）。

### 3.7 设置与开发体验

- 设置页新增「插件」分区：列表、启用开关、权限查看、打开插件目录、重新加载。
- 开发模式：监视插件目录文件变化自动重载；日志查看过滤 `plugin=<id>`。
- SDK 提供 `npm create switchly-plugin` 脚手架、类型定义、esbuild 打包脚本、`switchly-plugin validate` 本地校验 manifest 与 UI schema。

## 4. 初期 API / SDK 范围与涉及系统能力

### 4.1 能力清单（apiVersion 1）

| 命名空间 | 方法 | 权限声明 | 底层系统能力 | 首期 | 备注 / 风险 |
|---|---|---|---|---|---|
| `ui.*` 组件 + `render` 返回 slot | 声明式界面（§3.5） | 无 | SwiftUI 宿主渲染，复用 `DesignTokens` / `GlassEffect` / SF Symbols | ✅ | 不开放自由绘制 |
| `onAction(id, value?)` | 按钮 / 开关 / 滑块回调 | 无 | 宿主事件分发 + 乐观更新 | ✅ | 点击不得触发切窗（R2） |
| `ctx.app` / `ctx.window` | 只读属性 | 无 | 现有 `WindowMonitorService` / `AccessibilityService` 快照 | ✅ | 不额外调用 AX |
| `ctx.media.nowPlaying()` | 标题、艺人、专辑、播放状态、进度、是否喜欢 | `media.nowPlaying` | AppleScript / ScriptingBridge（Music、Spotify） | ✅ | 需「自动化」授权；每目标 App 独立弹窗 |
| `ctx.media.togglePlayPause/next/previous()` | 播放控制 | `media.control` | 首选 AppleScript；兜底 CGEvent 媒体键 | ✅ | 媒体键无法指定目标 App |
| `ctx.media.setLiked(bool)` | 喜欢 / 取消 | `media.control` | Music：`favorited`（新）/ `loved`（旧）属性 | ✅ | Spotify 不支持，`canLike=false` |
| `ctx.app.activate()` / `ctx.window.focus()` | 激活 / 聚焦 | `window.focus` | 复用现有切窗实现 | ✅ | 区分「激活」与「已聚焦」 |
| `ctx.storage.get/set` | 插件私有 KV | 无 | 宿主沙盒目录 JSON，配额 64KB | ✅ | 可在设置页清除 |
| `ctx.t()` / `ctx.locale` | 本地化 | 无 | 宿主 | ✅ | |
| `ctx.log.*` / `console.*` | 日志 | 无 | `AppLogger` | ✅ | 限速，防刷屏 |
| `ctx.invalidate()` / `refreshInterval` | 重绘 | 无 | 宿主调度 | ✅ | 仅预览可见时 |
| `ctx.appleScript.run(templateId, args)` | 调用预置脚本模板 | `appleScript:<bundleID>` | `NSAppleScript` | ⏳ 二期 | 仅模板，防任意代码执行 |
| `ctx.media.*`（通用 Now Playing） | 任意 App | `media.nowPlaying` | MediaRemote 私有框架 | ❌ 暂不 | macOS 15.4+ 受限，脆弱 |
| `ctx.ax.press(...)` | 点击目标 App 按钮 | `ax.control` | Accessibility | ❌ 暂不 | 脆弱、权限过大 |
| 网络 / 文件 / 子进程 | — | — | — | ❌ 不提供 | 隐私边界 |

### 4.2 首期官方示例插件

1. `music-controls`：Apple Music 完整控制（含喜欢）。
2. `spotify-controls`：Spotify 播放控制（无喜欢）。
3. `window-badge`：仅用 `ctx.window` 显示最小化 / 全屏角标，用于演示最小权限插件。

### 4.3 SDK 包结构（npm）

| 包 | 内容 |
|---|---|
| `@switchly/plugin-sdk` | `definePlugin`、`ui` 构建器、`ctx` 类型定义、apiVersion 常量 |
| `create-switchly-plugin` | 脚手架模板（TS + esbuild + locales） |
| `@switchly/plugin-cli` | `build`、`validate`、`link`（软链到插件目录便于调试） |

## 5. 分阶段计划

| 阶段 | 内容 | 验证 |
|---|---|---|
| Phase 0 原型 | Swift 硬编码 Music 叠层：AppleScript 延迟、自动化权限弹窗、按钮点击不触发切窗 | 真机截图；日志中 AppleScript 耗时 |
| Phase 1 运行时 | `PluginRegistry` + `PluginRuntime`（JSC）+ manifest 解析 + UI schema 校验 | 单测：manifest 解码、超时、异常、卸载清理 |
| Phase 2 渲染 | `PluginOverlayView` 接入 Dock 预览，主题 / 减少动态 / 键盘焦点 | 浅色、深色、玻璃开关截图 |
| Phase 3 能力桥 | media / window / storage / log 桥 + 权限持久化 + 设置页 | fake Bridge 单测 + 真机 Music / Spotify |
| Phase 4 SDK | npm 包、脚手架、CLI、示例插件、开发文档 | 从零创建插件到运行的端到端演练 |

## 6. 风险与待决事项

| 编号 | 事项 | 当前判断 | 后续动作 |
|---|---|---|---|
| R1 | AppleScript 调用延迟可能影响叠层首帧 | 2026-10-23 实测：osascript 单次约 130ms（含进程启动）；状态、元数据、`favorited` 读写、playpause / next / previous 均可用；无当前曲目返回 -1728 | 宿主内 NSAppleScript 在专用串行队列执行；首次自动化授权在后台请求，未授权前不渲染叠层 |
| R2 | Dock 预览按钮点击与切窗手势冲突 | 插件按钮用 SwiftUI `Button`，与现有红绿灯按钮同一方式截获点击；离屏渲染已核对布局 | 真机悬停点击验收 |
| R2a | 流媒体（`URL track`）曲目 AppleScript 取不到封面（`count of artworks` 为 0） | 2026-10-24 实测；本地曲库曲目可取到 | 现状显示音符占位图；是否读取 Music 本地缓存或其他来源待用户裁决，联网方案与隐私政策冲突不采用 |
| R3 | 自动化权限对用户的打扰 | 每目标 App 首次一次 | 设置页提供引导说明 |
| R4 | 第三方插件恶意行为 | 能力白名单可控 | 不开放任意脚本 / 网络 |
| R5 | 插件分发渠道 | 初期仅本地安装 | 市场化需单独评估隐私影响 |
| R6 | MediaRemote 通用方案 | 暂不采用 | 跟踪系统变化 |

## 7. 决策台账

| 编号 | 日期 | 结论 | 依据 |
|---|---|---|---|
| D01 | 2026-10-23 | 运行时采用内嵌 JavaScriptCore + 声明式 UI（方案 A） | §2 对比；零依赖、隐私边界、视觉一致 |
| D02 | 2026-10-23 | 首期不提供网络、文件、任意 AppleScript、MediaRemote 能力 | §3.6、§4.1 |
| D03 | 2026-10-23 | 界面采用「slot + 声明式组件树」由宿主绘制；首期不开放 Canvas / WebView 自由绘制 | §3.5.5；视觉一致、无障碍、性能 |
| D04 | 2026-10-23 | 插件包以 `globalThis.__switchlyPlugin = { render, onAction }` 注册（SDK `definePlugin` 产出 IIFE）；超时为软超时：JSC 无公开中断 API，迟到结果丢弃，连续 3 次停用 | Phase 1 实现；`make test-unit` 通过 |
| D05 | 2026-10-23 | 预留远端（GitHub）加载：所有来源统一为「本地目录 + 同一加载器」，`PluginOrigin` 目前为 `builtin` / `user`；远端来源将新增 `remote(repo, commit)`，流程为用户显式确认 → 按固定 commit 下载到缓存目录 → 校验 sha256 → 首次展示权限清单 → 交给现有加载器。默认关闭，不做后台自动更新 | 用户要求后续支持 GitHub 地址；联网与 PRIVACY_POLICY「完全本地」冲突，启用前需单独修订隐私政策并经用户裁决 |
| D06 | 2026-10-23 | 内置插件随 App 打包于 `Contents/Resources/Plugins`，搜索顺序内置优先，同 id 的用户副本不能覆盖内置插件 | 防止伪装内置插件获取已授予的权限 |
| D07 | 2026-10-23 | `bottomBar` 高度上限由约 30% 调整为缩略图高度 45%（`DesignTokens.Plugin.bottomBarMaxHeightFraction`）；默认 120pt 卡片仅放一行紧凑按钮，无窗口时在空状态区域显示曲目与进度 | 120×75 卡片 30% 仅 22pt，放不下带内边距的按钮行；Music 常在无窗口时使用 |
| D08 | 2026-10-23 | 授权规则：内置插件默认按声明启用、可关闭；用户插件默认关闭，确认权限清单后启用；插件更新新增的权限保持“尚未允许”且不注入，直到再次确认。运行时只拿到「声明 ∩ 已确认」的权限，授权变化时重建 JS 环境 | §3.6；`PluginAuthorizationTests` |
| D09 | 2026-10-23 | 封面由宿主经媒体桥按曲目 persistent ID 缓存读取，只在插件树含 `image{artwork}` 且有已授权 `media.nowPlaying` 的插件时请求；曲名滚动速度、停顿放 `MotionTokens`，减少动态效果时退化为截断 | §3.5.2、§4.1 |
| D12 | 2026-10-30 | 动画由插件声明、宿主本地播放：新增通用 `scene` 组件（apiVersion 2）。D03 调整为「不开放逐帧 JS 绘制，开放声明式场景」。宿主不含任何抽卡专有代码；原生 `Gacha*` 视图 / ViewModel / 引擎已删除，改由内置 JS 插件 `com.switchly.weather-gacha` 实现 | §9；用户要求「迁移成真正的 JS 插件，注意功能对齐和性能」。与 `feat/plugin-scene-api` 分支的 §8 提案（D10 / D11，待确认）并行，合并前需对齐 |
| D13 | 2026-10-30 | 新增权限 `media.library`（`ctx.media.library.pickRandom / play / pause`）；AppleScript 仍由宿主生成，插件只传曲风关键词与曲目 ID | §9.4；`WeatherGachaPluginTests.testPluginWithoutLibraryPermissionCannotReachTheLibrary` |
| D15 | 2026-10-30 | 经用户裁决，新增**唯一联网例外**：可选在线天气（默认关；数据源为 Open-Meteo，免费、无需密钥；宿主 `OnlineWeatherService` 先按城市查一次坐标再取天气，15 分钟一次、缓存 30 分钟、日志不记城市与坐标）；插件侧新增 `weather.current` 权限只读宿主快照，插件本身仍无网络。需同步 `PRIVACY_POLICY.md` §1 与 `AGENTS.md` §6 | §9.4；`OnlineWeatherTests` |
| D16 | 2026-10-30 | 同一槽位允许多个插件叠放（每槽位 ≤3，按注册顺序），取代「先到的插件独占槽位」。原因：音乐控制与天气抽卡都要 `center`，独占导致抽卡被挤掉 | `DockPluginOverlayModel.maxEntriesPerSlot`；`PROBE center=[music-controls, weather-gacha]` |
| D14 | 2026-10-30 | 插件设置新增 `select` / `number`；值存 `AppSettings.pluginValues`（旧设置缺该字段读为空），toggle 仍在 `pluginSettings`。`gachaPreferences` 因从未发布，直接移除而不迁移 | §9.5；`PluginSceneTests.testSettingsWithoutPluginValuesStillDecode` |

## 9. Scene 引擎（已实现，D12）

> §8 的「Scene API 提案」目前只在另一分支 `feat/plugin-scene-api`（D10 / D11，均待确认），本分支实现了它；两边的字段命名、预算与未实现项差异见 [scene-api-alignment.md](scene-api-alignment.md)，合并那条分支后再统一。
>
> 实现：`Models/Plugins/PluginScene.swift`（解码即校验）、`SceneEvaluator.swift`（纯函数求值）、`Views/PluginSceneDrawing.swift`（Canvas 绘制）、`PluginSceneView.swift`（时间线、悬停与点击）。

### 9.1 为什么不是逐帧 JS

JS 每次调用有软超时，逐帧过 JSC 桥会占满插件队列。插件改为**声明一次**：图层 + 随时间变化的规则；宿主按墙钟 `t = now - epoch` 本地求值并绘制。JS 只在状态变化（选牌、揭晓、播放、播完）或宿主 1 秒轮询时运行。同一个 `key` + `epoch` 的重复输出是同一段动画，不会重头播放。

### 9.2 节点

`{ type: "scene", key, epoch, width, height, fit, fps, restAt, layers }`

- `width` × `height` 是设计尺寸（pt）；`fit: "width"` 等比缩放到可用宽度（最大 1.3 倍），`"cover"` 铺满并裁切，用作 `zstack` 的背景（不撑大布局）。
- `epoch`：场景时间 0 对应的 Unix 秒（JS 用 `Date.now()/1000`）。`fps` 10–60，默认 30。
- 图层坐标原点在**自身锚点**（`anchor`，默认居中），子层坐标相对父层锚点。`kind`：`group`（可 `clip`、`shatter`）、`rect`（`radius`）、`ellipse`、`text`、`symbol`（SF Symbol）、`wave`（可拨动的线）、`emitter`（粒子）、`sprite`（精灵图，`pluginAsset` 路径）。
- 填充：`"#RRGGBB[AA]"`、`{linear}`、`{angular}`；文字色另有 `"$label"` / `"$secondaryLabel"`，由宿主按浅色 / 深色解析。
- 属性随时间变化：`tracks`（关键帧 `{t, v, e}`，`e` ∈ linear / in / out / inOut / hold，`loop` 周期循环）覆盖基础值；`osc`（振荡叠加：`amp`、`freq`、`phase`、`start`、`end`、`decay`、`wave` ∈ sin / pulse / abs）累加。可动属性：x、y、w、h、rotation、scale、scaleX、scaleY、opacity、blur、angle。
- `hit: {id, label, hoverScale}`：该层成为可点击区域（命中框按当前时刻的位置与缩放算出）；点击以 `hit.id` 触发 `onAction`，悬停缩放与 `showOnHover`（让另一层随悬停淡入）由宿主本地处理。`label` 供 VoiceOver。

### 9.3 预算、静帧与停表

| 项 | 上限 / 行为 |
|---|---|
| 图层 / 深度 / 粒子 / 命中区域 | ≤ 160 / ≤ 6 / ≤ 400（单发射器 ≤ 120）/ ≤ 12，超限整段 scene 解码失败，该次渲染被拒 |
| 关键帧 | 每条轨道 ≤ 160 个 |
| 减少动态效果 | 取 `restAt`（缺省为 `settledAt`）一帧；振荡、循环、粒子、拨弦、碎裂动画不播放；`ctx.reduceMotion` 同步告知插件 |
| 停表 | `settledAt`（所有轨道、振荡、发射器、碎裂、精灵播完的时刻）后约 0.3 秒停止时间线，悬停时短暂恢复；含循环或不衰减振荡的 scene 视为永不停止 |
| 不可见 | Dock 面板关闭即移除视图，时间线随之销毁；VM 同时被卸载 |

### 9.4 `media.library`

`ctx.media.library.pickRandom(keywords)` → `{persistentID, title, artist, bpm, matchedGenre} | null`；`play(id)`；`pause()`。与 `media.nowPlaying` 共用同一条 AppleScript 串行队列；关键词会过滤为字母、数字、空格、连字符，ID 只保留字母数字。

### 9.4.1 `weather.current`

`ctx.weather.current()` 同步返回宿主已获取的天气快照 `{condition, temperature, wind, source:"online"}`，未启用、未配置、过期或无权限时为 `null`。宿主在面板显示时与设置变更时按 15 分钟下限刷新；插件不得触发请求，也拿不到密钥与原始响应。未获得该权限时，`ctx.weather` 对象不存在（而非返回 null）。

### 9.5 设置类型

`manifest.settings[]` 的 `type`：缺省 `toggle`；`select` 需 `options: [{value, title}]` 且默认值是其中之一；`number` 可带 `min` / `max` / `step`，默认值须在范围内。不匹配则 manifest 解码失败。设置页按类型渲染开关、下拉或步进器。

### 9.6 天气抽卡插件对照

| 原生实现 | 插件里的对应 |
|---|---|
| `GachaEngine` / `GachaCardPool` / 保底 | `main.js` 的 `POOL` / `draw()`（`__test` 暴露给单测） |
| `GachaViewModel` 状态机与定时 | `state` + `setTimeout` + `ctx.invalidate()`，选歌与播放走 `media.library`，播放监控用 `nowPlaying` 轮询 0.5 秒 |
| `GachaStaffCountdown`（Canvas 物理） | `countdownLayers()`：按原公式每 0.03 秒采样音符位姿成关键帧；谱线 `wave`（拨弦 + 收拢），金粉 `emitter`（跟随音符 / 顶部先散） |
| `GachaCardView`、`ShatterView`、`MagicPlayButton`、`DancingNotes`、`GachaBackdrop`、天气图标 | `cardLayer()`（含流光、边框、脉冲光晕、碎裂）、`playButton()`、背景 `backdropScene()`、`headerLayers()` |
| 偏好设置里的天气控件 | manifest 的 `select` / `number` / `toggle` 设置 |

已知差异：面板隐藏保留插件 VM，回合在重开面板后继续（实测期望行为，`DockPluginOverlayModel.unload()` 才是硬重置）；Again 按钮与卡片没有原生键盘焦点（`⏎` 默认键），改由 VoiceOver 的 hit 动作触达；选歌文案过长时缩小至 70% 后截断由插件负责。
