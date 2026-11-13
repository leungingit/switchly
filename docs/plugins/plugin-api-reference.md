# Switchly 插件 API 参考

> 更新日期：2026-11-06。本文以当前宿主的 Swift 解码、运行时、资源读取与包校验实现为准。机器可读能力清单见 [`Plugins/api/capabilities.json`](../../Plugins/api/capabilities.json)，manifest Schema 见 [`Plugins/api/manifest.schema.json`](../../Plugins/api/manifest.schema.json)。`scene3d` 章节保留 D26 冻结时的历史实现状态；当前宿主已注入 `ctx.uiFeatures` 快照，本轮扩展其中的 `lineChart`／`lineChartSeries` 字段，不新增平行协商入口。UI 特性可用性仍以每次快照为准。

## 1. 当前兼容状态

宿主接受 `apiVersion` 为 `1` 或 `2`。当前实现只检查版本是否位于 `1...2`，没有按版本逐项拒绝较新的节点或设置；文档将 Scene、`fs.read`、`select` / `number` 设置作为 v2 约定发布。新插件应使用 `apiVersion: 2`。

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 注册、`render`、`onAction` | 稳定 | 同步、Promise 与抛错均由宿主统一处理。 |
| `ctx.capabilities` | 稳定 | 按能力名区分 supported / granted / available，不能把权限声明当作实现。 |
| `ctx.app/window/locale/settings` | 稳定 | 每次调用传入只读快照。 |
| `ctx.t/invalidate/reduceMotion` | 稳定 | 本地化、请求重绘与减少动态效果。 |
| `ctx.storage` | 稳定 | Promise JSON 键值存储；单值 64 KiB，单插件总量 1 MiB。 |
| `ctx.weather.current()` | 稳定 | 只读宿主已有快照；无授权或不可用时返回 `null`。 |
| `media.nowPlaying/control/library` | 稳定 | 当前桥接目标是 Apple Music，受用户授权限制。 |
| `ctx.fs` | 稳定 | 只读、根目录白名单、调用预算与路径解析限制。 |
| 声明式 UI | 稳定 | `render()` 返回经过解码校验的槽位树。 |
| `ctx.uiFeatures` | 稳定 | 宿主 UI 特性快照，包含 scene3d、panel、activity、lineChart、lineChartSeries、timeline；缺失或 false 时回退，与用户权限分离。 |
| `scene3d` | 未实现 | D26 合同冻结：仅 `apiVersion: 2` 且 `ctx.uiFeatures.scene3d === true` 可用；当前宿主解码器仍按未知节点拒绝。 |
| Scene | 稳定 | 宿主本地播放，JS 不逐帧参与。 |
| 普通 `image.pluginAsset` | 稳定 | 复用 SceneAssets 路径与纹理预算，已通过真实图片渲染回归。 |
| `window.focus` | 未实现 | manifest 可声明，宿主不会注入对应 API。 |
| `appleScript:<bundleID>` | 未实现 | manifest 可声明，宿主不会向插件注入任意脚本能力。 |

“稳定”只表示当前宿主已有实现和契约边界，不表示 SDK 或 CLI 已通过 npm 发布。

## 2. 仓库、开发目录与预装制品

插件开发源位于外部仓库：

```text
../switchly-plugins/
└── plugins/
    └── <id>/
        ├── manifest.json
        ├── main.js
        ├── assets/                 # 可选
        └── locales/                # 可选
```

外仓：<https://github.com/leungingit/switchly-plugins>。

宿主预装制品未来使用 `.build/Plugins/<id>/`。第一阶段安装器接受用户选择的本地目录；不会自动联网拉取插件。

SDK 与 CLI 的源码位于本仓库：

- `Plugins/sdk/`
- `Plugins/cli/`

两者均为零外部依赖的本地工作区包。当前没有发布到 npm，不应在文档或安装说明中写成可从 npm 安装。

## 3. 插件包硬限制

宿主安装器与加载器对目录执行统一校验：

| 项目 | 限制 |
| --- | --- |
| 包根 | 必须是普通目录，不能是符号链接。 |
| 包内条目 | 最多 `1024` 个文件和目录。 |
| 包总大小 | 所有普通文件合计最多 `32 MiB`。 |
| `manifest.json` | 最多 `256 KiB`。 |
| `entry` 指向的入口 | 最多 `2 MiB`，必须是 UTF-8 普通文件。 |
| 符号链接 | 任意位置均禁止。 |
| `version` | 非空字符串；不强制 SemVer，以兼容历史 `version: "1"`。 |

入口必须位于插件目录内，不能使用绝对路径或包含 `..` 路径段。`assets/`、`locales/` 和 Scene 资源路径同样不能越出插件目录。

## 4. manifest

最小结构：

```json
{
  "id": "com.example.demo",
  "name": {
    "en": "Demo",
    "zh-Hans": "示例"
  },
  "version": "0.1.0",
  "apiVersion": 2,
  "matches": ["com.example.app"],
  "permissions": [],
  "entry": "main.js"
}
```

### 4.1 顶层字段

| 字段 | 类型 | 必填 | 当前行为 |
| --- | --- | --- | --- |
| `id` | string | 是 | 必须匹配 `^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$`，全局唯一。 |
| `name` | `{语言: 文本}` | 是 | 非空本地化显示名；值不能是空串或纯空白。 |
| `version` | string | 是 | 非空；不强制 SemVer。 |
| `apiVersion` | `1 \| 2` | 是 | 范围外拒绝加载。 |
| `summary` | `{语言: 文本}` | 否 | 设置页的一句话说明。 |
| `matches` | string[] | 是 | 非空 bundle ID 数组。 |
| `permissions` | string[] | 是 | 不能重复；未知值会导致解码失败。 |
| `entry` | string | 是 | 插件目录内的安全相对路径。 |
| `refreshInterval` | number | 否 | 必须大于 `0` 且不超过 `86400` 秒；实际重绘下限为 1 秒。 |
| `settings` | setting[] | 否 | 设置 key 与选项 value 必须唯一。 |
| `fsRoots` | fsRoot[] | 否 | 仅在声明 `fs.read` 时出现且必须非空。 |
| `defaultEnabled` | boolean | 否 | 只对内置插件生效；缺省视为 `true`。 |

宿主会忽略 manifest 中未声明的额外字段。不要依赖未知字段产生运行效果。

### 4.2 权限字符串

| 权限 | 状态 | 注入内容 |
| --- | --- | --- |
| `media.nowPlaying` | 稳定 | `ctx.media.nowPlaying()`。 |
| `media.control` | 稳定 | `ctx.media.togglePlayPause/next/previous/setLiked()`。 |
| `media.library` | 稳定 | `ctx.media.library`。 |
| `weather.current` | 稳定 | 数据授权；`ctx.weather.current()` 始终存在，但无授权时返回 `null`。 |
| `fs.read` | 稳定 | `ctx.fs`；必须同时声明非空 `fsRoots`。 |
| `window.focus` | 未实现 | 可声明，但不会注入聚焦 API。 |
| `appleScript:<bundleID>` | 未实现 | 可声明，但不会注入任意 AppleScript API。 |

运行时只获得“manifest 声明 ∩ 用户已确认”的权限。用户插件默认关闭；内置插件的 `fs.read` 也必须由用户单独允许。

### 4.3 设置项

设置值通过 `ctx.settings[key]` 传入。未保存时使用 manifest 默认值，用户保存后覆盖默认值。

开关：

```json
{
  "key": "showCover",
  "title": {
    "en": "Show album cover",
    "zh-Hans": "显示专辑封面"
  },
  "default": true
}
```

`type` 缺省为 `"toggle"`，`default` 必须是 boolean。

选择：

```json
{
  "key": "condition",
  "type": "select",
  "title": {
    "en": "Weather",
    "zh-Hans": "天气"
  },
  "default": "clear",
  "options": [
    {
      "value": "clear",
      "title": {
        "en": "Clear",
        "zh-Hans": "晴"
      }
    }
  ]
}
```

`options[].value` 必须唯一，`default` 必须是其中一个值。

数字：

```json
{
  "key": "temperature",
  "type": "number",
  "title": {
    "en": "Temperature",
    "zh-Hans": "温度"
  },
  "default": 20,
  "min": -40,
  "max": 50,
  "step": 1
}
```

`step` 若存在必须大于 `0`，默认值必须位于 `min...max`。`effect` 当前唯一被宿主处理的值是 `"hideWindowPreviews"`。

### 4.4 `fsRoots`

```json
{
  "permissions": ["fs.read"],
  "fsRoots": [
    {
      "id": "sessions",
      "path": "~/Library/Application Support/Example/Sessions",
      "summary": {
        "en": "Read session state.",
        "zh-Hans": "读取会话状态。"
      }
    }
  ]
}
```

根路径必须以 `/` 或 `~/` 开头，不能包含 `..`。宿主还会拒绝：

- 用户主目录之外的路径。
- `.ssh`、`.aws`、`.gnupg`、`.codex`、`.kube`、`.docker`、GCP 凭据目录。
- Keychain、Cookies、Safari、Chrome、Firefox、Brave、Edge 的用户资料目录。
- 顶层包含 `auth.json`、`.env` 或 `.credentials.yaml` 的目录。
- 通过符号链接落到敏感位置或根目录之外的路径。

插件只能提交根 `id` 和根内相对路径，不会拿到真实绝对路径。

## 5. 运行时

入口必须注册 `globalThis.__switchlyPlugin`：

```js
globalThis.__switchlyPlugin = {
  async render(ctx) {
    return [];
  },

  async onAction(ctx, id, value) {
    ctx.invalidate();
  }
};
```

使用 SDK：

```js
import { definePlugin, ui } from "@switchly/plugin-sdk";

export default definePlugin({
  render(ctx) {
    return [{
      slot: "center",
      node: ui.text({
        value: ctx.app.name,
        style: "title"
      })
    }];
  }
});
```

`definePlugin()` 负责写入 `globalThis.__switchlyPlugin`。宿主不会加载 ES module 或执行 npm 解析；正式插件仍需在进入宿主前形成可执行的单入口 JavaScript。

### 5.1 可用全局

- `console.log/info/debug/warn/error`
- `setTimeout`、`clearTimeout`
- JavaScriptCore 原生 Promise

每个插件最多保留 32 个待执行定时器。预览隐藏时宿主调用 `suspend()`：暂停计时、保留剩余延时和 VM 状态，结束等待中的宿主调用，返回 suspended；再次显示时恢复计时。未完成的 JS Promise 可能仍留在 VM，但旧调用结果不能覆盖新调用。`unload/unmount` 才取消全部 Timer 并释放 VM；同步死循环仍可能阻止真正清理，但主线程不再同步等待该队列。日志单条截断到 500 字符。

以下全局不存在：`fetch`、`XMLHttpRequest`、`WebSocket`、`require`、`process`。插件不能直接联网、启动子进程或读取任意文件。

### 5.2 调用与超时

`render` 和 `onAction` 可以同步返回、返回 Promise 或抛错。宿主通过 `JSON.stringify` 接收返回值；`undefined` 按 `null` 处理。

可选 `prepare(ctx)` 与首次媒体读取并行，返回同格式的初始 UI；旧宿主忽略该方法，没有声明时行为不变。`ctx` 仅提供 `app`、`window`、`locale`、`settings`、`reduceMotion`、`uiFeatures`、`ui` 和 `t`，不提供媒体、文件、存储、天气或 invalidate 接口。准备界面不代表播放状态，宿主不注册其动作；只有正式 render 的媒体批次通过校验后才启用动作并原子替换。初始界面复用完整 UI／Scene3D 解码和预算，关闭、切目标或正式批次已提交后会丢弃迟到结果。该阶段沿用软超时，不增加硬隔离保证。

生产 Dock 预览的调用超时为 1 秒。JavaScriptCore 没有公开的硬中断 API，因此这是软超时：

- 超时后宿主丢弃迟到结果。
- 连续 3 次超时后停用该运行时。
- 已经进入死循环的脚本不保证能在 1 秒时被强制终止。

插件不可把软超时当成强制调度或资源隔离机制。

### 5.3 独立宿主校验工具

`make plugin-verifier` 生成 `.build/tools/switchly-plugin-verify`，编译的是 App 实际 Runtime、包校验和 UI/Scene 解码器，不复制一个 JS 模拟实现。可将二进制与 CLI 包交给外部插件开发者，后者不需要宿主源码。

```sh
node Plugins/cli/bin/switchly-plugin.js verify ../switchly-plugins/plugins/com.switchly.music-controls --host .build/tools/switchly-plugin-verify
```

工具只连接假媒体/天气与临时 storage，不授权真实 fs.read；只验证入口执行和初次 render 的宿主互操作，不能代替系统权限、文件锁、媒体动作或真实 Dock 验收。CLI 将整个校验进程限制在 5 秒并可终止，同进程 App Runtime 本身仍没有硬隔离。CLI 的 create、validate、build、verify 均为本地命令，npm 包尚未发布。

## 6. `ctx` 快照

`ctx` 是每次 `render` / `onAction` 调用生成的只读快照。

| 成员 | 类型 | 说明 |
| --- | --- | --- |
| `ctx.capabilities` | object | 能力名到 `{ supported, granted, available }` 的映射；含媒体、天气、文件、未实现窗口能力及基础 storage；未知键为空。available 不代表已获得系统自动化许可或实际文件存在，调用仍须处理错误。 |
| `ctx.uiFeatures` | object，可选 | 宿主 UI 能力协商快照，与权限表分离。字段为 `scene3d: boolean` 及可选的 `panel`、`activity`、`lineChart`、`lineChartSeries`、`timeline` 布尔值。字段缺失表示宿主没有该协商，插件必须返回 2D 树；不能据 `apiVersion: 2` 推断 3D 可用。 |
| `ctx.app` | object | `{ bundleID, pid, name, lastActiveAt }`。`lastActiveAt` 为 Unix 秒或 `null`。 |
| `ctx.window` | object | `{ windowID, title }`；`title` 最多约 40 个字符。 |
| `ctx.locale` | string | 首选语言，例如 `zh-Hans-CN`。 |
| `ctx.settings` | object | 只包含 manifest 声明项，值可为 boolean、number 或 string。 |
| `ctx.reduceMotion` | boolean | 系统“减少动态效果”是否开启。 |
| `ctx.t(key)` | `(string) => string` | 读取 `locales/<language>.json`，回退 `en`，最后回退 key。 |
| `ctx.invalidate()` | `() => void` | 请求宿主尽快重新调用 `render`。 |
| `ctx.storage` | object | Promise、插件私有的 JSON 键值存储。 |
| `ctx.weather` | object | 始终存在；`current()` 返回快照或 `null`。 |
| `ctx.media` | object，可选 | 仅当至少一个 media 权限被授权时存在。 |
| `ctx.fs` | object，可选 | 仅当 `fs.read` 被授权时存在。 |

### 6.1 `ctx.storage`

```ts
get(key: string): Promise<JSONValue | null>;
set(key: string, value: JSONValue): Promise<void>;
remove(key: string): Promise<void>;
clear(): Promise<void>;
```

四个方法均返回 Promise。值是 JSON 可表达的数据：

- key 不能为空，UTF-8 编码后最多 256 字节。
- 单个序列化值最多 64 KiB。
- 单个插件的全部存储最多 1 MiB。
- 存储按插件隔离，由宿主管理持久化位置。
- 插件只使用自己的键名，不选择路径，也不直接读写宿主文件。

超出预算时写入不能成功；插件不应依赖超出限制的数据仍被保存。

### 6.2 `ctx.weather`

```ts
ctx.weather.current(): {
  condition: "clear" | "cloudy" | "rain" | "snow" | "fog" | "storm" | string;
  temperature: number;
  wind: number;
  source: "online";
} | null;
```

`ctx.weather.current()` 是同步读取，不会从插件发起网络请求。以下情况返回 `null`：

- 用户未确认 `weather.current`。
- 在线天气功能关闭。
- 地点未配置。
- 请求失败或结果已过期。

即使 manifest 未声明 `weather.current`，方法对象仍存在，但返回 `null`。这是当前运行时与 `ctx.fs` / 媒体方法“未授权则不存在”不同的明确行为。

### 6.3 `ctx.media`

未授权的方法不会出现在对象上。

```ts
ctx.media.nowPlaying(): Promise<NowPlaying | null>;
ctx.media.togglePlayPause(): Promise<void>;
ctx.media.next(): Promise<void>;
ctx.media.previous(): Promise<void>;
ctx.media.setLiked(on: boolean): Promise<void>;
```

`NowPlaying`：

```ts
{
  playing: boolean;
  title: string;
  artist: string;
  album: string;
  position: number;
  duration: number;
  progress: number;
  liked: boolean;
  canLike: boolean;
}
```

资料库：

```ts
ctx.media.library.pickRandom(keywords?: string[]): Promise<{
  persistentID: string;
  title: string;
  artist: string;
  bpm: number;
  matchedGenre: boolean;
} | null>;
ctx.media.library.play(persistentID: string): Promise<void>;
ctx.media.library.pause(): Promise<void>;
```

当前媒体桥只支持 Apple Music。插件只提交固定命令、关键词或曲目 ID，不提交 AppleScript。封面字节由宿主读取并绘制，不传给插件 JS。

宿主内部每批叠层渲染固定一份媒体读取上下文，文字与图片整组发布；`media.control` 不获得读取快照的权限，动作使用实时授权与定向控制。候选 `CompositeMediaBridge` 通过注入启用，以 MediaRemote 精确来源／进程及前后歌曲采样做保守配对，不可靠时整组回退 AppleScript；它继续提供喜欢与资料库接口。**默认装配仍为 `MusicAppleScriptBridge`**，当前发行包没有新增 Adapter。共享读取与封面解码预算见 [接入设计](mediaremote/music-mediaremote-integration-plan.md)，公开 JS 字段与 manifest 不变。

### 6.4 `ctx.fs`

`ctx.fs` 只有用户确认 `fs.read` 后才存在。

```ts
ctx.fs.list(root: string, path?: string): Promise<FSEntry[]>;
ctx.fs.stat(root: string, path?: string): Promise<FSEntry>;
ctx.fs.readText(
  root: string,
  path?: string,
  options?: { maxBytes?: number }
): Promise<string>;
ctx.fs.scan(
  root: string,
  path?: string,
  options?: {
    depth?: number;
    suffix?: string;
    modifiedWithin?: number;
  }
): Promise<FSScanEntry[]>;
ctx.fs.isLocked(root: string, path?: string): Promise<boolean>;
```

返回类型：

```ts
interface FSEntry {
  name: string;
  isDir: boolean;
  size: number;
  mtime: number; // Unix 秒
}

interface FSScanEntry {
  path: string;  // 相对于传入 path
  size: number;
  mtime: number; // Unix 秒
}
```

限制：

- 每次 `render` 或 `onAction` 最多 50 次文件操作。
- `readText` 默认和单次上限均为 256 KiB；只接受 UTF-8 普通文件。
- `list` 最多返回 500 项。
- `scan` 深度钳制到 `1...3`，最多访问 5000 项并返回 200 项。
- `scan` 不跟随符号链接，结果按修改时间从新到旧排序。
- `isLocked` 只探测其他进程的非等待共享锁，不读取或写入内容。

路径错误、越界、未知 root、过大文件、非 UTF-8 或调用超限会令对应 Promise 拒绝。

## 7. 声明式 UI

`render()` 返回：

```ts
null | undefined | Array<{
  slot: "bottomBar" | "center" | "topTrailing" | "titleAccessory";
  node: UINode;
}>
```

每次输出最多 64 个节点，树深最多 8。每个 slot 最多出现一次；所有 button、toggle、slider、Scene hit 与 `scene3d` hit 的 action ID 在整个输出内必须唯一。唯一例外是 `scene3d` 的 hit 与其自身 `fallback` 子树复用同一业务 action ID，因为两条展示分支不会同时可见；其他跨 slot 或跨节点复用仍被拒绝。

### 7.1 布局节点

| `type` | 字段 |
| --- | --- |
| `hstack` | `children`，可选 `spacing: xs\|s\|m`，可选 `align: leading\|center\|trailing` |
| `vstack` | `children`，可选 `spacing: xs\|s\|m`，可选 `align: leading\|center\|trailing` |
| `zstack` | `children` |
| `spacer` | 无字段 |
| `surface` | `children`，可选 `material: glass\|plain`，默认 `glass` |
| `screen` | `children` |
| `wheel` | `children` 必须恰好 5 项，顺序为上、左、右、下、中；空位用 `spacer` |

### 7.2 交互节点

| `type` | 字段 |
| --- | --- |
| `button` | `id`、`symbol`、`label` 必填；`size: s\|m\|l`，`variant: plain\|prominent`，`enabled`，`selected` |
| `toggle` | `id`、`symbolOn`、`symbolOff`、`label` 必填；`isOn` 可选 |
| `slider` | `id`、`value`、`label` 必填；`value` 钳制到 `0...1`，`step` 必须在 `(0, 1]` |

`id`、`symbol`、`label` 等字符串不能为空。`onAction` 收到：

- button：`value === null`
- toggle：`value === 1` 或 `0`
- slider：拖动结束时提交的 `0...1` 数值
- Scene hit：由具体 hit 区域决定，通常为 `null`

### 7.3 展示节点

| `type` | 字段 |
| --- | --- |
| `text` | `value` 必填；`style: title\|body\|caption`；`lines` 钳制到 `1...3` |
| `progress` | `value` 钳制到 `0...1`；`style: linear\|circular`；可选 `rate` |
| `image` | `source` 必填；`size: s\|m\|l`；`corner: s\|m` |
| `badge` | `value` 必填；`tone: neutral\|accent\|warning` |
| `marquee` | `value` 必填；减少动态效果时退化为截断 |
| `scene` | Scene 对象展开到节点中 |

`image.source`：

```ts
{ symbol: "play.fill" }
{ artwork: true }
{ pluginAsset: "assets/icon.png" }
```

`artwork` 需要 `media.nowPlaying`，由宿主读取封面。普通 `pluginAsset` 与 Scene 的图片共享 `SceneAssets` 的有界资源加载逻辑。每张边长最多 2048 像素，解码前检查尺寸与 32 MiB 总预算，路径必须位于插件目录内；加载失败显示占位图。

## 8. Scene

Scene 是声明式动画，由宿主按时间计算并本地绘制。插件只提交场景描述，不接收逐帧回调。

```js
ui.scene({
  key: "pulse-1",
  epoch: Date.now() / 1000,
  width: 320,
  height: 180,
  fps: 30,
  fit: "width",
  restAt: 1.2,
  layers: [
    {
      kind: "rect",
      x: 0,
      y: 0,
      w: 320,
      h: 180,
      fill: "#112233"
    }
  ]
});
```

### 8.1 场景字段

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `key` | 是 | 相同 key 的重新渲染不会重启动画。 |
| `epoch` | 是 | 场景时间 0 对应的 Unix 秒。 |
| `width` / `height` | 是 | 范围 `16...1200`。 |
| `fps` | 否 | 钳制到 `10...60`，默认 30。 |
| `fit` | 否 | `width` 或 `cover`，默认 `width`。 |
| `restAt` | 否 | 减少动态效果时显示的场景时间。 |
| `layers` | 是 | 图层数组。 |

### 8.2 图层

`kind` 可为：

- `group`
- `rect`
- `ellipse`
- `text`
- `symbol`
- `wave`
- `emitter`
- `sprite`
- `image`

通用几何与外观字段：

```ts
x, y, w, h, anchor,
rotation, scale, scaleX, scaleY,
opacity, blur, angle, radius,
fill, stroke, strokes, add,
from, until, showOnHover,
tracks, osc, children,
shatter, hit, emitter, wave, sprite, image
```

只有 `group` 可以嵌套 `children`。`text`、`symbol`、`wave`、`emitter`、`sprite`、`image` 分别要求对应载荷。

颜色：

- `#RRGGBB`
- `#RRGGBBAA`
- `$label`
- `$secondaryLabel`

填充可以是纯色、线性渐变或角向渐变：

```ts
"#112233"
{ linear: { colors: ["#112233", "#445566"], from: [0.5, 0], to: [0.5, 1] } }
{ angular: { colors: ["#112233", "#445566"], center: [0.5, 0.5] } }
```

线性渐变最多 6 个颜色，角向渐变最多 8 个。描边宽度钳制到 `0.1...16`。

### 8.3 轨道与振荡

`tracks` 以关键帧驱动 `x/y/w/h/rotation/scale/scaleX/scaleY/opacity/blur/angle`：

```ts
{
  prop: "scale",
  keys: [
    { t: 0, v: 0.8, e: "out" },
    { t: 0.3, v: 1.1, e: "inOut" }
  ],
  loop: 1.5
}
```

每个 track 最多 160 个 key；key 由宿主按 `t` 排序。`loop` 若存在必须大于 `0.05` 秒。缓动为 `linear/in/out/inOut/hold`。

`osc` 在 track 或基础值上叠加：

```ts
{
  prop: "rotation",
  amp: 4,
  freq: 2,
  phase: 0,
  start: 0,
  end: 2,
  decay: 1.5,
  wave: "sin",
  power: 3
}
```

波形为 `sin/pulse/abs`。`power` 钳制到 `0.5...8`。

### 8.4 粒子、波纹、破碎、sprite 与图片

- `emitter.count` 钳制到每发射器最多 120；整个 Scene 最多 400 粒子。
- `life` 钳制到 `0.1...4` 秒。
- `region` 必须是 4 个数字：`x, y, w, h`。
- `wave.length` 最小为 1；最多保留 8 个 pluck。
- `shatter.cols/rows` 钳制到 `1...8`，持续时间钳制到 `0.1...3`。
- `sprite` 必须提供 `asset/cols/rows/t0`；`cols/rows` 最大 16，`fps` 钳制到 `1...60`。
- `image` 图层必须提供 `image` 相对路径。
- Scene 的 `sprite.asset` 与 `image` 路径不能是绝对路径或包含 `..`。

### 8.5 hit 与预算

图层可带：

```ts
hit: {
  id: "open",
  label: "Open",
  hoverScale: 1.05
}
```

`id` 与 `label` 必须非空，`hoverScale` 钳制到 `0.8...1.3`。点击后宿主调用：

```ts
onAction(ctx, hit.id, value)
```

Scene 总预算：

- 最多 160 层。
- 最大深度 6。
- 最多 400 粒子。
- 最多 12 个 hit。
- hit ID 必须唯一。

`ctx.reduceMotion === true` 时宿主使用 `restAt` 或稳定时间静帧。

## 9. `scene3d`（合同冻结，宿主未实现）

> 状态：D26 已冻结合同；T04–T07 完成前宿主不具备该能力。`apiVersion: 2` 本身不代表可渲染 3D。插件必须先读取 `ctx.uiFeatures.scene3d`，仅在值为 `true` 时返回 `scene3d`；字段缺失或为 `false` 时返回原有 2D 树。机器可读定义与预算见 `Plugins/api/capabilities.json` 的 `ui.scene3d`。

### 9.1 能力协商与分发（D25/D26）

- `scene3d` 是 v2 协商式增量能力，与 `ctx.capabilities` 权限表分离。`ctx.uiFeatures` 不表示用户授权，只表示宿主 UI 是否支持。
- 不支持 `scene3d` 的 v2 宿主收到 `scene3d` 时按未知节点拒绝整次输出，不会静默显示空白；JS 的 `fallback` 不能补救这种情况，插件必须直接返回 2D 树。
- 已发布 v1.3.0 宿主只接受 v1 包，会在加载阶段拒绝 v2 包；JS 回退无法让旧宿主接受 v2 包。
- D25/D26 分发规则：同一插件 ID 保留两条发行线。v1 线使用 `apiVersion: 1`，继续供 v1.3.0 等旧宿主；v2 线使用 `apiVersion: 2`，供支持 `scene3d` 的新宿主。任一宿主发行只能锁一条线：v1 包不进入新宿主，新宿主只加载 v2 包；v2 包在不支持 `scene3d` 的宿主上仍按上面的协商返回 2D。外仓目录、分支、revision 与锁文件细节由 T09 落地，不在本文虚构尚未存在的外仓目录名。
- 不放宽 v1 对未知节点的拒绝，也不把 `apiVersion: 2` 当作 3D 可用性的替代判断。

### 9.2 节点字段

`scene3d` 只能作为 slot 的根 `node`，不得嵌套在任意 `children` 或 `fallback` 内；每个 slot 最多一个 `scene3d`。

| 字段 | 必填 | 类型与约束 |
| --- | --- | --- |
| `type` | 是 | 固定字符串 `"scene3d"`。 |
| `key` | 是 | 非空字符串，最多 64 个字符；同一插件实例内用于复用场景。相同 key 且相同 asset 的重复 `render()` 不重建场景；asset 变化时重新加载。 |
| `asset` | 是 | 插件包内相对路径，必须是单个 `.glb` 文件；不能是绝对路径或包含 `..`。实际文件大小 ≤ 8 MiB，且在交给 GLTFKit2 前通过宿主 GLB 预检。 |
| `fit` | 否 | 首期只允许 `"contain"`，默认 `"contain"`；宿主按模型包围盒等比缩放并完整放入槽位。 |
| `camera` | 否 | `{ yaw?: number; pitch?: number }`，角度单位为**度**，默认 `yaw = 0`、`pitch = 0`。`yaw ∈ [-180, 180]`，`pitch ∈ [-89, 89]`，必须是有限数字。 |
| `rotate` | 否 | `{ horizontal?: boolean; vertical?: boolean; pitchMin?: number; pitchMax?: number }`，见 9.3。 |
| `surfaces` | 否 | 数组，最多 5 项，默认空数组；见 9.4。 |
| `hits` | 否 | 数组，最多 12 项，默认空数组；见 9.5。 |
| `fallback` | 是 | 必填的受限 2D 节点，不得为 `scene3d`，其子树也不得包含 `scene3d`。`fallback` 与 3D 分支不会同时可见，但计入 64 节点/深度 8 预算。 |

相机约定：`yaw = 0, pitch = 0` 时相机位于 glTF `+Z` 轴、看向原点，`+Y` 为上；正 `yaw` 把相机绕 `+Y` 轴转向 `+X` 一侧，正 `pitch` 抬高相机。相机距离、FOV、近远裁剪、灯光、环境反射、抗锯齿与色彩空间由宿主固定，不开放 `zoom`、FOV、灯光或任意着色器。插件侧本期不提供环境预设字段；若后续增加，必须另行冻结并保持旧资产默认行为。

### 9.3 `rotate`

| 字段 | 默认 | 约束 |
| --- | --- | --- |
| `horizontal` | `true` | 是否允许水平拖动改变 `yaw`。 |
| `vertical` | `true` | 是否允许垂直拖动改变 `pitch`。 |
| `pitchMin` | `-55` | `[-89, 89]`，必须有限且 ≤ `pitchMax`。 |
| `pitchMax` | `55` | `[-89, 89]`，必须有限且 ≥ `pitchMin`。 |

`horizontal: false` 固定 yaw，`vertical: false` 固定 pitch。`ctx.reduceMotion === true` 时保留直接拖动，但禁用惯性与自动回正；普通模式下的惯性参数不开放给插件。

### 9.4 `surfaces`

| 字段 | 必填 | 类型与约束 |
| --- | --- | --- |
| `node` | 是 | 引用 glTF `node.name`，见 9.6。名称必须存在、唯一，解析到单个可见网格，且 UV 完整；同一 `node` 不能被多个 surface 或任一 hit 重复引用。 |
| `size` | 是 | `[width, height]`，两个整数，单位是**输出纹理像素**而非布局 pt；每边 `1...1024`。 |
| `content` | 是 | 单个受限 2D 节点；其子树只允许 `hstack`、`vstack`、`zstack`、`spacer`、`text`、`progress`、`image`、`badge`、`marquee`。禁止 `button`、`toggle`、`slider`、`wheel`、`screen`、`surface`、`scene`、`scene3d` 与任意 HTML。 |

表面内容按左上原点栅格化，映射到网格 UV 后，从模型正面观察时文字与图像必须正立，不得上下颠倒或镜像。内容复用现有 `PluginUINode` 的文本、封面、进度与本地化语义；`image.artwork` 受 `media.nowPlaying` 授权约束。表面子树计入 §7 的 64 节点/深度 8 预算。动态表面按实例隔离，每张 ≤1024×1024、RGBA 约 ≤4 MiB，最多 5 张；不写入其他卡片。表面纹理只在内容实际变化时更新，旋转不触发重新栅格化。

### 9.5 `hits`

| 字段 | 必填 | 类型与约束 |
| --- | --- | --- |
| `node` | 是 | 引用 glTF `node.name`，要求同 9.6；必须解析到单个可见网格；同一节点可同时是 surface 目标（贴图后的可点击按钮），命中只看几何。 |
| `id` | 是 | 非空 action ID，在 `scene3d` 内唯一；与 `fallback` 子树复用同一 ID 是唯一例外。 |
| `label` | 是 | 非空可访问标签；用于独立语义树，不能为空或仅含空白。 |
| `value` | 否 | `number | null`，默认 `null`；点击时作为 `onAction(ctx, id, value)` 的 value。 |
| `enabled` | 否 | boolean，默认 `true`；`false` 时不派发动作，也不进入可执行的可访问动作。 |
| `sector` | 否 | `"top" \| "right" \| "bottom" \| "left"`。以命中节点包围盒中心为原点，按节点局部 X/Y 平面的对角线分成四个象限。同一节点可承载多个命中（如整圈点击转盘环带），但此时每个命中必须声明互不相同的 `sector`，且不能与未声明 `sector` 的命中混用。 |

命中只取前方可见命名网格：透明占位、被遮挡背面、侧面与不可见网格不参与点击；拖动超过宿主点击阈值不派发点击动作，背面/侧面不得派发正面动作。`onAction` 仍走现有路由，插件不得假设屏幕坐标或 iPod 专用分支。

### 9.6 glTF 命名与资产

- 语义标识只按 glTF `node.name`，按 `mesh.name` 查找一律无效；名称区分大小写，不做模糊或子串匹配。
- 被 surface/hit 引用的名称必须在资产内唯一且对应单个可见网格；`GLBPreflight` 已拒绝空名与重复名，缺失、歧义或 UV 不完整在运行时令当前 `scene3d` 降级到 `fallback`。
- 只接受单文件、自包含 glTF 2.0 `.glb`。`buffer.uri`、`image.uri`、外部文件、绝对路径、网络 URI、Draco/KTX2 与未批准扩展均拒绝。允许扩展首期仅 `KHR_materials_clearcoat`、`KHR_materials_emissive_strength`、`KHR_materials_unlit`。
- 表面网格必须具备完整 `TEXCOORD_0`；文字方向与 UV 方向一致性由 T04 在真实模型上验收。

### 9.7 预算硬值

| 项目 | 上限 |
| --- | --- |
| 单个 `.glb` | 8 MiB |
| 整个插件包 | 32 MiB（沿用 §3） |
| mesh | 128 |
| 三角形 | 150000 |
| 单个资产节点 | 256 |
| 静态纹理边长 | 2048 |
| 静态纹理累计解码 | 每插件 32 MiB |
| 动态表面 | 最多 5 张，每张 ≤1024×1024（RGBA 约 ≤4 MiB） |
| `surfaces` | 5 |
| `hits` | 12 |
| 声明 UI 树 | 64 节点、深度 8；`scene3d`、surface content 与 `fallback` 均计入 |
| 最小可读槽位 | 220×380 pt（候选值已冻结；真实 Dock 尺寸尚未实测，见 G0 未通过） |

静态纹理累计解码指 glb 内嵌图片与 `pluginAsset`/`image` 的累计预算；动态表面按实例另行计算，不能借静态预算绕过 2 张/每张 1024 的限制。减少动态效果不改变预算。

### 9.8 降级与错误语义

声明结构错误令**整次 `render` 输出被拒绝**，与 §10 的现有规则一致；包括：未知节点、缺 `key`/`asset`/`fallback`、空 `key`/`asset`、非法 asset 路径、`fit` 非 `contain`、相机或 `rotate` 数值非有限/越界、`pitchMin > pitchMax`、`surfaces > 5`、`hits > 12`、surface `node` 空或重复、`size` 非整数/越界、surface content 含禁用节点、hit `node`/`id`/`label` 空、同一节点的 hit `sector` 重复或与无 `sector` 的 hit 混用、`scene3d` 内 hit ID 重复、`fallback` 含 `scene3d`、节点/深度超预算、action ID 跨分支重复（hit 与其自身 fallback 的例外除外）、`scene3d` 非 slot 根或每 slot 多于一个。

运行期资产/渲染错误**只令当前 `scene3d` 降级到 `fallback`**，其他 slot 保持；记录有界错误码，不记录窗口标题等敏感文本：

- `scene3d.assetMissing`：资产不存在或不可读。
- `scene3d.preflightRejected`：GLB 预检拒绝。
- `scene3d.decodeFailed`：GLTFKit2 解码或场景创建失败。
- `scene3d.nodeNotFound`：surface/hit 引用的 `node.name` 不存在。
- `scene3d.nodeAmbiguous`：名称对应多个可见网格或无法解析为单一网格。
- `scene3d.uvMissing`：表面网格缺少完整 UV。
- `scene3d.renderFailed`：SceneKit 渲染或纹理创建失败。
- `scene3d.slotTooSmall`：槽位实际内容小于 220×380 pt。

窄槽判定使用宿主布局测量的实际内容尺寸，不要求插件轮询窗口尺寸；宽度小于 220 pt **或**高度小于 380 pt 即使用 `fallback`。3D 与 `fallback` 不同时可见，`fallback` 内的动作 ID 只在其可见时参与路由。

## 10. 错误与输出校验

- 未注册 `__switchlyPlugin`：运行时不会挂载。
- `render` / `onAction` 抛错：对应调用失败，错误写入宿主日志。
- 输出不是合法 JSON 数据、slot 重复、节点过深或过多、action ID 重复：整次输出被拒绝。
- 未知节点类型、未知枚举、必填字段缺失、空交互标签：解码失败。
- 普通插件错误和非法输出不会修改宿主窗口状态。

日志字段包含插件 ID、阶段与耗时。分享日志前仍应检查其中是否含窗口标题摘要等本地信息。

## 11. SDK

`Plugins/sdk/` 是零外部依赖的本地包：

- `definePlugin(plugin)`：校验 `render` / 可选 `onAction`，注册 `globalThis.__switchlyPlugin` 并返回原对象。
- `ui.hstack/vstack/zstack`
- `ui.spacer/surface/screen/wheel`
- `ui.button/toggle/slider`
- `ui.text/progress/image/badge/marquee`
- `ui.scene`
- `ui.scene3d`（合同冻结，宿主未实现；仅 v2 且 `ctx.uiFeatures.scene3d === true` 时由插件返回）
- `ui.lineChart(items)`（仅 panel 且 `ctx.uiFeatures?.lineChart === true` 时由插件返回，否则回退）
- `ui.segmented/dateRange/barChart/grid`
- `index.d.ts`：完整 ctx、manifest、UI、Scene、`scene3d` 类型。

示例：

```js
import { definePlugin, ui } from "@switchly/plugin-sdk";

export default definePlugin({
  async render(ctx) {
    const count = (await ctx.storage.get("launches")) ?? 0;
    await ctx.storage.set("launches", Number(count) + 1);
    return [{
      slot: "titleAccessory",
      node: ui.badge({
        value: String(await ctx.storage.get("launches")),
        tone: "accent"
      })
    }];
  }
});
```

SDK 不提供 Node、DOM 或网络 polyfill。宿主只执行最终入口 JavaScript；SDK 的 ES module 需要由插件仓库自身的构建流程转换为宿主可执行单入口。

## 12. CLI

`Plugins/cli/` 同样零外部依赖，可执行：

```sh
node Plugins/cli/bin/switchly-plugin.js api describe --json
node Plugins/cli/bin/switchly-plugin.js validate <插件目录>
node Plugins/cli/bin/switchly-plugin.js validate <插件目录> --json
node Plugins/cli/bin/switchly-plugin.js build <插件目录>
node Plugins/cli/bin/switchly-plugin.js build <插件目录> --out <输出根目录>
node Plugins/cli/bin/switchly-plugin.js create <目标目录>
```

`validate` 检查：

- manifest JSON、必填字段、ID、API 版本与非空 version。
- 32 MiB / 1024 entries / manifest 256 KiB / entry 2 MiB 包预算。
- 包根和包内任意符号链接。
- entry 存在、可读、UTF-8、不越界。
- 设置 key 唯一、选项 value 唯一、默认值类型与范围。
- 权限白名单、重复权限和未实现权限警告。
- `fs.read` 与 `fsRoots` 成对出现，root ID 唯一并做基本敏感路径检查。
- `locales/*.json` 是字符串字典。
- 静态 `pluginAsset`、`asset`、`image` 与 `assets/...` 字符串引用的基本路径和文件存在性。
- 包内所有 `.glb` 普通文件（不依赖 manifest 或入口是否显式引用）执行预检，检查容器结构、自包含 BIN、未批准扩展、bufferView 边界、节点/网格/三角形与纹理预算、空名或重复节点名。CLI 当前仅识别 PNG/JPEG 内嵌纹理，检查可能比使用 ImageIO 的宿主更严格；CLI 通过后宿主仍会在交给 GLTFKit2 前再次校验，宿主是最终防线。

`build` 只会在验证通过后把插件目录原样复制到：

```text
<输出根目录>/<id>/
```

默认输出根目录为当前工作目录下的 `.build/Plugins/`。它不执行 TypeScript 转译、打包或压缩，也不伪造完整编译器。

`create` 不依赖外部模板或网络，会生成最小 `manifest.json`、`main.js` 和双语 locale，并立即运行同一套 `validate`。可用 `--id`、`--name`、`--match` 指定插件 ID、显示名和目标 bundle ID。

CLI 的 `prepack` 会把权威 `Plugins/api/capabilities.json` 与 `manifest.schema.json` 复制到包内 `contract/`；发布后的 `api describe --json` 只读取包内 contract，不依赖本仓库相对路径。

测试：

```sh
node --test Plugins/sdk/test/sdk.test.js Plugins/cli/test/cli.test.js Plugins/cli/test/glb.test.js
```

## 13. 安装、覆盖与更新

第一阶段安装策略：

- 只接受用户选择的本地目录。
- 内置插件使用某 ID 后，用户包不能使用同一 ID 覆盖，也不能通过安装器卸载内置插件。
- 同 ID 用户插件更新会在完整校验与复制后替换当前版本。
- 用户插件更新后必须重新授权；权限增加时尤其不能沿用旧授权。
- 校验或复制失败时保留当前版本。

预装制品未来从 `.build/Plugins/<id>/` 进入宿主打包流程；该路径表示构建产物布局，不表示插件可以从网络自动安装。

## 14. 版本与兼容原则

- `apiVersion` 是运行协议主版本；当前支持 `1` 和 `2`。
- `version` 是插件自身版本，只要求非空，不强制 SemVer。
- 新插件应声明 `apiVersion: 2`。
- `scene3d` 是 v2 的协商式增量能力，只有 `ctx.uiFeatures.scene3d === true` 才可用；`apiVersion: 2` 本身不代表宿主支持 3D。
- D26 分发规则下，v1 2D 包继续供旧宿主，新宿主只加载 v2 包；两条发行线不能混进同一宿主的锁文件。
- 发布包格式、运行协议、SDK 和宿主版本分别演进，不能用一个版本号代替全部含义。
- 当前没有公开 npm 发布，不应把本地包名当成已发布制品。
- 未在能力清单标记 `stable` 的能力不得在插件市场、官网或 README 中宣传为稳定。


## 窗口卡片截图（本地开发增量）

manifest 可声明 `renderScope: "window"`，缺省仍为 `"app"`。窗口范围插件各自绑定卡片上下文；`matches: ["*"]` 可匹配所有应用。普通应用范围插件保持原挂载行为。titleAccessory、topTrailing、bottomBar 在各窗口卡片挂载；center 仍属于应用级内容，窗口范围插件不应用它替代整个窗口条。

`window.capture` 必须由用户明确确认，预装包也不自动获得。获准后提供 `ctx.capture.window({ mode: "full" | "region" })`，只接受 mode，不接受 windowID、PID、文件名或路径；目标由宿主动作上下文绑定。仅真实 onAction 的有效调用期间可提交一次，render、受控定时器或已结束调用保存的引用不能开始截图。`ctx.capabilities["window.capture"]` 区分 supported、granted、available；available 为当前屏幕录制权限与宿主提交器均就绪，不表示所有窗口内容均可读。

返回 Promise 仅确认短提交：`{status:"accepted"}` 或 `{status:"failed",reason}`。accepted 不表示已保存、复制或分享；长流程由独立宿主会话持有，Dock 隐藏后仍继续。窗口消失、最小化、撤权、超时与其他失败由宿主处理，不把旧缩略图当成新截图。插件不会收到图片像素、文件路径或分享接收方。预览/Worker 使用纯模拟提交器，不链接真实抓取流程。

首期先截取完整冻结位图；region 模式在冻结图上选择区域。系统标注使用「预览」：用户保存并关闭图片后，显式返回宿主读取修改，再复制、选择保存位置或通过系统分享。只有外部编辑需要临时 PNG；不写入 ThumbnailDiskCache。详见 [窗口截图合同](window-capture-plan.md) WC-D08～D13。

窗口入口支持 button.variant=labeled（显示标签并扩大同一按钮点击区）；ctx.presentationID 为一次叠层展示的宿主标识，可重置展开状态，不用于窗口身份。

窗口范围的 ctx.app.pid 表示当前卡片窗口的实际拥有进程，bundleID/name 仍表示 Dock 目标产品；宿主将拥有进程、进程启动时间与 windowID 绑定。window 范围不接受 center 输出；卡片标题行固定容纳小尺寸控件，面板高度预算共用同一几何值。

## 应用活动与独立插件面板（v2 可选增量）

契约真源为 [活动时间线计划](activity-timeline-plan.md) AT-D08～D17。`apiVersion: 2` 的 manifest 可声明 `surfaces: ["panel"]` 或同时包含 `"dockPreview"`，省略保持原 Dock 行为；`matches: ["*"]` 仍必填。菜单栏「插件面板…」按插件身份打开独立面板，不按前台应用匹配。仅声明 panel 的插件不在 Dock 装载。

`ctx.surface` 为 `"panel"` 或 `"dockPreview"`；panel 的 `ctx.app`、`ctx.window` 是 `null`，不能冒充某个应用的目标上下文。面板输出 `[{slot:"panel",node:...}]`，`presentationID` 标识一次展示。Dock 槽位行为不变；两个表面共享现有 VM 与可见性租约，插件须按 surface/presentationID 隔离自身展示状态。旧宿主没有 `ctx.surface` 时，新面板插件返回空树。SDK 以 `PluginPanelContext` 和 `definePanelPlugin` 表达新上下文，旧 `PluginContext` 的 app/window 类型保持不变。

### 分层授权

记录应用活动、活动截图采样都由宿主设置显式开启，均默认关闭。`activity.read` 授权读取时长；`activity.snapshots` 还允许展示历史小图，需同时获得前者。预装也需明确批准；权限读取不自动开启采集，也不与 `window.capture` 合并。未获 activity.read 时不注入 `ctx.activity`；缺少截图授权时不提供 `snapshots`。supported/granted/available 分开判断，采集关闭不等于已保留历史不可读取。

### 查询接口

全部方法返回 Promise，时间为 epoch 秒、半开范围 `[from,to)`，最大400天；每次 render/action 最多8次活动调用、全 VM 同时最多4次。响应不超过1 MiB；非法范围、超预算或过期游标明确失败，不伪造完整结果。查询过程中撤权、清除或卸载会丢弃旧结果。

```typescript
summary({from, to, groupBy?: "app"|"hour"|"day"|"month", timeZone?: string})
// {items:[{bundleID,name,seconds,sessions,bucketStart?,bucketEnd?}],
//  availableFrom:number|null,revision:number,recording:boolean,screenshotsEnabled:boolean}
sessions({from, to, bundleID?, limit?, cursor?})
// {items:[{id,bundleID,appName,start,end,seconds,endReason}],nextCursor:string|null,revision:number}
snapshots({from, to, bundleID?, limit?, cursor?})
// {items:[{ref,capturedAt,bundleID,sessionID?}],nextCursor:string|null,revision:number}
```

summary 最多1000行，每行对应一个应用及可选时间桶；时区为 IANA 名称，缺省使用本机时区。跨日与夏令时由 Calendar 裁剪；区间单调时长按墙钟片段比例分配。sessions 每页最多100条，snapshots最多6条，游标绑定查询、页大小、采集代次与已读前缀摘要；尾部追加且已读前缀不变时可继续翻页，修改／删除／插入已读记录、保留期裁剪或清除换代后应从第一页获取。revision 继续表示数据更新，不单独使历史游标失效。`availableFrom` 表示当前保留范围下界，无任何保留记录时为 null，不能据空结果推断更早没有使用。

过期游标的 Promise 拒绝值为字符串 `activityCursorExpired`；其他查询失败仍为 `activityQueryFailed`。插件可以在本批请求全部结束后，清除旧游标并至多从第一页重新加载一次；不能绕过每次 render/action 的 8 次调用和同时 4 次预算。清除、撤权等失效仍拒绝为 `activityInvalidated`，不得按游标过期自动恢复。

图片 ref 是短期不透明 UUID，宿主绑定插件身份、数据代次、有效期；只供 `image.source.activitySnapshot` 使用。不能读像素或路径，不能跨插件解析；清除、撤权或文件过期后失效。文件读取桥拒绝 Activity 目录及其后代，祖先目录也不能用于穿透读取。

### 面板节点

以下节点仅面板输出可用，仍受总节点64、深度8限制；不能出现在 scene3d 纹理中。

| type | 主要字段 | 动作与限制 |
| --- | --- | --- |
| segmented | id、options、selected | 最多6个选项；动作值是选项索引 |
| dateRange | id、from、to、label | `id.from`/`id.to` 分别发送数字 epoch 秒；范围最多400天 |
| barChart | items:[{label,value}] | 最多12行，value为非负有限数；按秒展示时长 |
| lineChart | items:[{label,value}] | 最多64点；label≤200 UTF-8 bytes，value为非负有限秒数；复用 `PluginBarItem` |
| timeline | items:[{timestamp,content}] | 最多12项；timestamp为非负有限epoch秒，content递归计入整树预算 |
| grid | children | 最多6个子节点，用于分页小图 |
| image | source:{activitySnapshot:ref} | 宿主注入解析器，权限不足只显示占位 |

`lineChart` 是 v2 的通用有界折线节点，`items` 复用 `PluginBarItem` 的 `{label,value}` 形状；宿主按 UTF-8 检查 label 最多 200 字节，value 必须有限且非负，最多 64 点。SDK 的 `ui.lineChart(items)` 只生成 wire shape 并复制数组，和 `ui.barChart` 一样不重复做运行时限制校验，越界数据由宿主解码器拒绝。它只能在 `panel` 槽位出现：Dock 预览和 `scene3d` 纹理 surface 不接受；panel 的普通 2D fallback 可用，Dock fallback 则递归拒绝；整棵树仍受 64 节点、深度 8 预算限制。`ctx.uiFeatures?.lineChart === true` 时才返回该节点，旧宿主缺少 `ctx.uiFeatures`、字段缺失或为 `false` 时须回退到已有 2D 节点，不能根据 `apiVersion: 2` 推断可用。`prepare(ctx)` 也注入这个静态协商字段，但动作注册与迟到结果规则不变。机器可读约束见 `Plugins/api/capabilities.json` 的 `ctx.uiFeatures` 与 `ui.lineChart`。

当 `ctx.uiFeatures.lineChartSeries === true` 时，可用 `ui.lineChart(items, {label, series})` 追加固定色线条和图例：`label` 命名汇总，`series` 为最多 6 个 `{label, items}`。每列最多 64 点，必须与汇总的时间标签逐项一致；所有系列标签非空且不超过 200 UTF-8 字节，各 value 沿用非负有限约束。宿主使用共同纵轴，每条线全程保持一种色，汇总以虚线和淡面积辅助区分，横轴不换色。缺少此协商字段时只发送原来的 `items`，不推断旧宿主支持多线。附加列和总列均只用于 panel，其他预算与拒绝规则不变。

Preview/Worker 只使用合成夹具，不能实例化 ActivityTrackingService、ActivityStore 或真实截图服务。主 App 系统行为和权限撤销仍须单独验收。


### 会话与截图的纵向时间线（AT-D17）

`ui.timeline(items)` 返回 `{type:"timeline",items:[{timestamp,content}]}`；`PluginTimelineItem.content` 沿用普通 `PluginNode`，时间戳为非负有限 epoch 秒，最多 12 项，容器及全部内容共同计入 64 节点／深度 8。宿主按输入顺序绘制左侧本地日期与秒级时间、中央连续轴线和节点、右侧内容，不自动猜测排序或会话归属。只在 `ctx.uiFeatures?.timeline === true` 时返回此节点，缺失或 false 时由插件按同顺序回退为纵向内容列表，内容须保留可读的时间。仅允许 panel，scene3d 纹理拒绝，panel 普通 2D fallback 可用，Dock fallback 递归拒绝。

`snapshots()` 的可选 `sessionID` 是对应会话的不透明 UUID，与 `sessions()` 的 `id` 对应，不是文件路径或图片像素。旧宿主未提供该字段，或所属会话不在当前加载页时，截图按 `capturedAt` 独立排列；不能按同一应用或时间近似猜测归属。活动插件保留独立的会话页和截图页，并明确说明当前只显示已经加载的页。
