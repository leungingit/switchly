# 插件独立预览内部契约

日期：2026-11-03（2026-11-04 增补默认场景、覆盖项、inspect 与 GUI 启动器；同日增补内置合成 fixture、fixture 来源与缺数据提示；2026-11-05 明确透明标题栏内的启动器顶部安全区）。版本：契约 v1（工具版本 0.1.0；本次为新增能力，场景 Schema 不变）。本文是预览工具内部各部分之间的合同；**可执行的权威检查**是 `Plugins/api/preview-*.schema.json`、`Tools/PluginPreview/` 下的测试与 `Tests/PluginPreview/` 下的回归脚本。契约文件变化时，`Tools/PluginPreview/contract-hash.sh --check` 必须同步更新（见第 7 节）。面向使用者的说明见 [使用指南](plugin-preview-guide.md)。

## 1. 边界

预览进程不装配 `PluginHost`、Dock、AX、真实媒体、天气网络或用户目录；每个 worker 只处理一个插件包。所有读取路径必须由调用者明确指定，包使用 `PluginPackageValidator` 校验，fixture 相对场景文件目录解析，拒绝越界、符号链接和非普通文件。默认场景使用的内置样例是预览 App 资源包内的固定合成数据，同样不读取真实系统数据；显式场景不会自动套用内置样例。每次 `run` 使用独立临时 storage；`dev` 重载时显式保留该会话 storage，重置和关闭时清除。初始授权为场景授予与 manifest 声明的**交集**；`supported` 由运行时实现决定，不接受 fixture 覆盖。正式宿主功能和权限配置不由预览改写。

槽位 `center`、`bottomBar` 反映 Dock 当前接入并会被截图；`topTrailing`、`titleAccessory` 仅作组件预览，不截图。只渲染未截图槽位的插件得到 `unsupported`/`no-capturable-slot`；什么都没渲染得到 `failed`/`empty-render`。`window.focus`、`appleScript` 标记不支持。

预览复用宿主的 Runtime、解码器与渲染代码本身；`Tools/PluginPreview/shared-source-check.sh` 禁止在 Tools/Tests 中另造核心类型，并要求预览 target 编译宿主源文件。

## 2. 场景

`schemaVersion` 为整数 `1`，必填 `id`、`environment`、`target`；未知字段一律拒绝。

- `environment`：`locale`（`en`、`zh-Hans`）、`appearance`（`light`、`dark`）、`glass`、`reduceMotion`、`contentWidthPoints`（>0）。
- `target`：`bundleID`、`appName`，可选 `titleSummary`、`lastActiveAt`。
- `fixtures`：`media`/`weather`/`fs`，相对场景目录的 JSON 文件；在**显式场景**中缺失表示对应合成能力不可用，不读取真实系统数据。推导场景的默认来源见 2.1；显式 `--fixture` 或 GUI 选择的文件覆盖内置样例。
- `grants`、`settings`、`storageSeed`：权限（与 manifest 取交集）、设置值、初始私有存储。无效设置、权限或路径在启动插件前拒绝。
- `clock`（可选）：`{ startEpochMs ≥ 0, seed: uint32 }`。存在时 JS 的 `Date`、`Math.random`、`setTimeout` 由虚拟时钟接管（`PluginVirtualClock`），Scene 绘制时刻使用同一虚拟时间；时间只在 `advance` 步骤前进。缺省保持实时行为，正式宿主默认不创建虚拟时钟。
- `steps`（可选，≤ 64）：`advance{ms}`（0…86 400 000，需要 `clock`）、`action{id, value?}`（业务动作，直接调用 `onAction`）、`expectText{contains}`、`nativeClick{label, expectAction? | expectDisabled?}`（原生输入，经可访问树 press）。未知类型返回 `unsupported`，字段错误返回 `invalid-scenario`。首个失败即停止，其后记 `skipped`；失败不产生截图。

Fixture Schema 为 `preview-media-fixture`、`preview-weather-fixture`、`preview-fs-fixture`；Schema 不替代运行时对字节数、文件类型、路径及 manifest 设置值的校验。媒体快照须包含公开 `NowPlaying` 的全部字段（含与位置和时长一致的 `progress`）。

### 2.1 默认场景推导（derived scenario）

未提供 `--scenario` 时，预览 App 在加载插件前从 manifest 推导一个标准场景；推导只有一个实现（`Tools/PluginPreview/Scenario/` 下的单一模型），输出仍走 `PreviewScenario.decode` 校验。worker 协议不变：App 把场景 JSON 写入该会话私有 `workRoot` 下的文件，再把该文件路径作为 `scenarioPath` 交给 worker。

| 场景字段 | 推导规则 |
| --- | --- |
| `id` | 固定 `default` |
| `environment` | `locale: "en"`、`appearance: "light"`、`glass: false`、`reduceMotion: true`、`contentWidthPoints: 360` |
| `target.bundleID` | `manifest.matches` 首项。`matches` 是精确 bundle ID（宿主用 `matches.contains` 匹配），不存在通配或模式 |
| `target.appName` | `bundleID` 最后一段，首字母大写（`com.example.app` → `App`） |
| `target.titleSummary` / `lastActiveAt` | 省略 |
| `grants` | manifest 声明的全部 `permissions` 的 `rawValue`（`appleScript:<bundleID>` 原样保留） |
| `settings` | 省略，由 manifest 默认值生效 |
| `fixtures` | 按 manifest 权限自动选择：声明 `media.nowPlaying`、`media.control`、`media.library` 任一时使用内置合成媒体样例；声明 `weather.current` 时使用内置合成天气样例；`fs.read` 不内置，需要显式文件（见 2.3） |
| `clock` | `{ "startEpochMs": 1700000000000, "seed": 1 }`，因此默认场景可作视觉基线 |
| `steps` | 省略，只渲染一次 |

内置样例随预览 App 资源分发，是固定的合成数据（媒体样例使用曲名 `Synthetic Evening`、艺人 `Fixture Ensemble`），不含任何真实系统数据。App 在运行时把它们复制进会话私有 `workRoot`，再以相对路径写入交给 worker 的场景文件；场景 Schema 与 worker 协议不变。

fixture 来源规则：

- 未提供文件时，media/weather 使用内置样例；`fs.read` 因内容取决于插件自身目录结构而**没有**内置样例，derived 默认场景下该能力不可用。
- 显式 `--fixture media=<文件>` / `weather=<文件>` / `fs=<文件>`（2.2），或 GUI 自定义模式选中的文件，覆盖对应内置样例。
- GUI 的「清除 / Clear」表示该能力不可用，**不会**回退到内置样例；这是为测试降级路径而保留的显式选择。
- 显式 `--scenario` 的语义完全不变：未在场景文件声明 `fixtures` 仍表示能力不可用，不会自动附加内置样例。
- 导出为场景文件时，内置样例作为文件复制到导出目录，并以相对路径引用；导出文件不再依赖预览 App 资源。
- `scenarioSource` 仍为 `derived`；fixture 来源不进入视觉基线的逻辑身份。

`matches` 为空属于 `invalid-package`（manifest 校验先失败），不提供目标应用回退值。推导结果与显式场景遵守同一套必填、未知字段拒绝和值域校验；`grants` 与 manifest 取交集的既有规则不变。

### 2.2 覆盖项（仅未给 `--scenario` 时）

覆盖项修改的正是 2.1 的推导结果。显式 `--scenario` 与任一覆盖项同时出现属于参数错误：`invalid-arguments`，退出码 2。App 与 CLI 的参数名完全一致；CLI 只做透传和基本形态校验，类型与 manifest 相关语义由 App 校验。

| 参数 | 作用 | 说明 |
| --- | --- | --- |
| `--locale en\|zh-Hans` | 替换 `environment.locale` | 只接受这两个值 |
| `--appearance light\|dark` | 替换 `environment.appearance` | 只接受这两个值 |
| `--glass` / `--no-glass` | 替换 `environment.glass` | 默认 `false`；`glass` 为真的运行不可作基线 |
| `--reduce-motion` / `--no-reduce-motion` | 替换 `environment.reduceMotion` | 默认 `true` |
| `--width <点数>` | 替换 `environment.contentWidthPoints` | 必须是大于 0 的数值；GUI 控件沿用 `PluginPreviewEnvironment` 的 300–720 范围 |
| `--grants <a,b,c\|none>` | 显式替换默认的“全部授权” | `none` 表示空授权；逗号分隔的 `rawValue`，重复或空项属于参数错误。替换后仍与 manifest 取交集，超出 manifest 的项被忽略 |
| `--set <key>=<value>` | 追加/覆盖 `settings[key]` | 可重复，但同一 key 只能出现一次。类型按 manifest 设置规格解析：`toggle` 只接受 `true`/`false`，`select` 必须命中 `options[].value`，`number` 必须是有限数值且落在 `min`–`max` 内；未知 key 或类型不符按 `invalid-settings`（1）处理 |
| `--fixture media=<文件>` / `--fixture weather=<文件>` / `--fixture fs=<文件>` | 为对应合成能力提供 fixture，并覆盖内置样例 | 三种 kind 都必须给出显式文件，没有不带文件的裸开关。可重复，每种 kind 最多一次；重复属于参数错误。文件必须存在且为普通文件，路径解析为绝对路径后透传；App 将其复制进会话 `workRoot`、场景内写相对路径，并继续执行既有的路径安全、文件类型、大小与 Schema 校验 |
| `--target-bundle-id <id>` | 替换 `target.bundleID` | 不得为空 |
| `--target-app-name <名>` | 替换 `target.appName` | 不得为空 |

未给出的覆盖项保持 2.1 的推导值。`--json`、`--out`、`--preview-tool` 的既有语义不变。

### 2.3 fixture 选择方式

fixture 来源分为三类：

- `builtin`：仅用于推导场景；media/weather 按 2.1 自动使用预览 App 内置的合成样例，`fs` 没有内置样例。
- `explicit`：调用者显式提供文件。CLI 对 `media`、`weather`、`fs` 三种 kind 统一使用 `--fixture <kind>=<文件>`，且只能与推导场景一起使用（2.2）；GUI 自定义模式为每种 kind 提供“选择文件…”控件。选中的文件覆盖同名内置样例；运行时复制到会话私有 `workRoot`，导出时复制到场景目录，再以相对路径写入场景。文件必须存在且是普通文件；缺少文件、kind 未知或文件不可用都属于参数错误（退出码 2），文件无法通过 Schema、大小或路径校验时按 `invalid-fixture`（1）处理。
- `none`：没有来源，对应合成能力不可用。`fs.read` 在 derived 场景下默认就是 `none`，需要显式文件；GUI 的「清除 / Clear」也会把 media/weather 置为 `none`，且不回退内置样例。

不存在“扫描某个目录并自动取名”的约定。显式 `--scenario` 不使用 `builtin`：场景文件未声明 `fixtures` 即表示 `none`，此时不能叠加 `--fixture`，需要在场景文件内声明相对路径。`inspect` 输出的来源见 3.2。

## 3. 命令、结果与退出码

`run` 和 `dev` 接受插件目录、`--preview-tool <App>`、可选的 `--scenario`；未给 `--scenario` 时使用 2.1 的推导场景，并允许 2.2 的覆盖项。`run` 另需 `--out`（必须是空目录，不覆盖），可选 `--json`。JSON 模式 stdout 只输出一个结果对象，诊断在 stderr，且只含固定诊断（不含 fixture、渲染内容或私密路径）。

| 退出码 | `status` | 含义 |
| --- | --- | --- |
| 0 | `passed` | 渲染与步骤通过，产物完整 |
| 1 | `failed` | 插件/场景问题（错误码见使用指南 §7） |
| 2 | — | 参数错误 |
| 3 | `unsupported` | 不支持的能力 |
| 4 | `environment-error` | 环境问题（无 GUI/授权、工具不配套、找不到工具） |

报告 `report.json`：`schemaVersion: 1`、`status`、`scenarioID`、`pluginID`、`pluginVersion`、`generation`、`packageHash`、`artifacts`、`versions`、`environment`、`failure?`、`steps?`。`environment` 含系统版本、架构、语言、外观、`displayScale`、`rendererRevision`、`glass`、`deterministicClock`。`steps` 仅在场景声明步骤时出现，每项为 `{index, type, source, status, detail?}`，`detail` 只用固定码。产物：`report.json`、`preview.png`、`ui-tree.json`（宿主解码器验证后的原始声明式树）、`actions.json`；失败时只有 `report.json`。截图失败不能返回成功；报告和日志不嵌入 fixture 内容、私密路径或图片 base64。

### 3.1 `scenarioSource`

报告 `report.json` 与 `--json` 的结果对象新增 `scenarioSource`，取值：

| 值 | 含义 |
| --- | --- |
| `derived` | 未给 `--scenario`，使用 2.1 的推导场景（可叠加 2.2 覆盖项） |
| `file` | 显式提供了 `--scenario` 文件 |

该字段只说明场景来源，不参与视觉基线的逻辑身份；基线仍以「插件 ID + 场景 ID」标识。旧报告没有该字段时按可选字段读取，不影响既有产物解析。推导场景的 `id` 恒为 `default`，因此同一插件的默认场景基线稳定；改用显式场景会因场景 ID 不同而不与默认场景基线比较。

### 3.2 `inspect`（无 GUI）

`SwitchlyPluginPreview inspect <插件目录>` 与 `--version-json` 同类：不显示窗口、不截图、不写产物、不执行插件 JS，也不需要屏幕录制授权。stdout 只输出一个 JSON 对象：

```json
{
  "schemaVersion": 1,
  "plugin": {
    "id": "com.example.hello",
    "name": { "en": "Hello", "zh-Hans": "Hello" },
    "version": "0.1.0",
    "apiVersion": 2,
    "matches": ["com.example.app"],
    "permissions": ["media.nowPlaying", "fs.read"]
  },
  "defaultScenario": {
    "schemaVersion": 1,
    "id": "default",
    "environment": { "locale": "en", "appearance": "light", "glass": false, "reduceMotion": true, "contentWidthPoints": 360 },
    "target": { "bundleID": "com.example.app", "appName": "App" },
    "grants": ["media.nowPlaying", "fs.read"],
    "clock": { "startEpochMs": 1700000000000, "seed": 1 }
  },
  "settings": [
    { "key": "showArtwork", "kind": "toggle", "default": true },
    { "key": "layout", "kind": "select", "default": "wide", "options": ["compact", "wide"] },
    { "key": "cardWidth", "kind": "number", "default": 360, "min": 300, "max": 720, "step": 20 }
  ],
  "fixtures": [
    { "kind": "media", "needed": true, "source": "builtin", "reason": "manifest declares media permissions" },
    { "kind": "weather", "needed": false, "source": "none", "reason": "manifest does not declare weather.current" },
    { "kind": "fs", "needed": true, "source": "none", "reason": "manifest declares fs.read; requires an explicit fixture file" }
  ]
}
```

- `plugin.name` 是 manifest 的显示名；可给本地化映射，也可给已解析的字符串，CLI 两种都接受。
- `defaultScenario` 是 2.1 的完整场景 JSON 对象，但不含内置样例的路径；内置样例由 App 在运行时解析并复制进会话 `workRoot`。直接把它保存为文件后交给 `--scenario` 会按显式场景语义运行（`scenarioSource` 变为 `file`）：media/weather 不再自动带内置样例，需要文件自行声明 `fixtures`。GUI 的“导出为场景文件…”会把内置样例复制到导出目录，因此导出文件能保留同样的输入。
- `settings` 只列 manifest 声明项：`default` 是 manifest 默认值；`options` 仅 `select` 出现，`min`/`max`/`step` 仅 `number` 出现。
- `fixtures` 固定给出 `media`、`weather`、`fs` 三项；`needed` 由 manifest 是否声明对应权限推导（媒体类权限 → `media`，`weather.current` → `weather`，`fs.read` → `fs`），`reason` 是稳定短说明，不含本机路径。`source` 表示推导场景将使用的来源：
  - `builtin`：将使用预览 App 内置样例（仅 media/weather）。
  - `explicit`：调用者已提供显式文件（GUI 选择或 `--fixture` 覆盖）。当前 `inspect` 命令行不接受 `--fixture`，因此实际输出只会是 `builtin` 或 `none`；该值用于描述 GUI/覆盖项解析后的来源。
  - `none`：没有来源；`needed: true` 且 `source: "none"` 时（典型为 `fs.read`），`reason` 明确要求显式文件。
- 失败使用与 `run` 相同的错误分类输出 JSON，并退出 1/3/4；CLI 参数形态错误退出 2。

CLI 侧为 `switchly-plugin inspect <插件目录> --preview-tool <App> [--json]`：`--json` 原样输出 App 的 JSON，否则输出人类可读摘要；版本握手与 `run` 相同。CLI 不包装 GUI 启动器。

### 3.3 GUI 启动器与自定义模式

- `SwitchlyPluginPreview` 无参数启动 GUI 启动器：不加载插件，窗口显示“选择插件目录 / Choose plugin directory”。启动器窗口为左右两栏布局：
  - **左栏（控制区，不透明面板背景）**：插件选择（打开/拖入/最近使用）、「默认 / 自定义」模式、场景各项设置、fixture、导出场景与诊断。
  - **右栏（工作台舞台）**：顶部显示双语舞台标题、当前目标应用与玻璃检查入口；主体使用明确的舞台背景承载底部一排 Dock 图标与悬停浮层，详见 3.5。
  - **原始桌面透射 / Raw desktop**：舞台标题栏提供开关，默认关闭；打开后右栏舞台背景与标题栏底色同时清空，窗口内容层保持透明，以便观察插件玻璃对实时桌面的采样。该模式只用于视觉检查，不能作为视觉基线。
  - 窗口宽度小于 900 pt 时两栏纵向堆叠（控制区在上，模拟 Dock 在下）；布局按窗口可用宽度计算，不做固定宽度。
- 控制区宽度约为可用宽度的 34%，夹在 340–380 pt；两栏布局下右栏至少保留 460 pt。调试面板默认收起；从舞台入口展开后追加面板宽度，不挤压工作台舞台。
- 启动器窗口使用 `fullSizeContentView` 和透明隐藏标题栏。左栏、工作台和最右侧调试面板共用的标题栏内距固定为 32 pt；各栏背景可延伸到窗口顶边，但标题、开关、标签页和面板操作必须从该内距以下开始，不得由祖先 `clipped()` 截断安全区外的背景。
- 插件选择：`NSOpenPanel`（“打开插件目录…”）、拖入目录、最近使用最多 8 条（存 App 自身 `UserDefaults`）。
- 模式切换「默认 / 自定义 / Default / Custom」：
  - **默认**：使用 2.1 的推导场景；控制区只读展示当前值，并标注“推导的默认场景 / Derived default scenario”。fixture 区显示推导将使用的来源，例如 `Fixtures: 内置样例（media, weather） / Built-in samples (media, weather)`；`fs.read` 需要时标注“需显式文件 / Needs a file”，没有任何来源时显示“无 / None”。
  - **自定义**：可编辑语言、外观、玻璃、减少动态效果、内容宽度（沿用 `PluginPreviewEnvironment` 的 300–720）、目标应用（`bundleID`/名称）、权限授予（manifest 声明项逐个开关）、manifest 设置项（按 `toggle`/`select`/`number` 渲染）、虚拟时钟（固定开关，`+1s`/`+1min`/自定义毫秒推进，复用 `advance`）、fixture（`media`/`weather`/`fs` 各自的“选择文件…/清除”）。选中文件覆盖内置样例；「清除 / Clear」把该能力置为不可用，**不回退**内置样例。`fs` 没有内置样例，只能选择文件或保持不可用。
- 任一草稿改动立即重渲染：重建会话并重置该会话存储，失败只在窗口内显示，不退出进程。渲染失败且缺少所需 fixture 时，窗口内显示 3.4 的固定修复提示。
- GUI 的所有可交互控件都必须有可访问标签：包括「打开插件目录… / Open Plugin Directory…」、模式切换、各编辑控件、fixture 的“选择文件…/清除”。标签用于 `nativeClick` 与辅助技术识别，不以颜色或位置替代。
- “导出为场景文件…”使用 `NSSavePanel`：把当前草稿写成合法场景 JSON；显式 fixture 与内置样例都作为文件复制到导出目录并用相对路径引用；写出后立即用 `PreviewScenario.decode` 回读校验。导出文件不依赖预览 App 资源。
- 草稿模型（`PreviewScenarioDraft`，可编辑字段 ↔ 场景 JSON 双向）是 GUI、覆盖项解析和导出的唯一来源。
- **范围声明**：本轮只改启动器窗口。`dev`/`run` 命令打开的窗口、截图路径（离屏 `PluginSlotSurface` 平铺）、可访问树匹配、退出码与视觉基线身份完全不变。启动器里的模拟 Dock 只模拟悬停展示与插件交互，**不是**本体 Dock 悬停的验证；真实 AX 悬停、跨屏、真实缩略图与桌面玻璃合成仍由本体验证（见 3.5 与 §8）。

### 3.4 缺数据提示（`plugin-script-error`）

当插件渲染以 `plugin-script-error` 失败，且 manifest 需要的某个 fixture 没有来源（`source: none`，例如用户清除了内置样例，或 `fs.read` 未提供文件）时，失败提示统一指向具体修复：

- GUI 窗口内文案、`run` 结果对象的 `error.message`、`report.json` 的 `failure.message` 使用固定文案：`该插件需要 <kind> fixture，请在自定义模式选择文件，或使用 --fixture <kind>=<文件>`。
- `<kind>` 为 `media`、`weather`、`fs`；英文文案保持同义并由 `Localizable.strings` 维护。
- 文案固定、不含本机路径、不回显插件内容；错误码仍为 `plugin-script-error`，退出码仍为 1，不新增错误码或退出码。
- 显式 `--scenario` 不能叠加 `--fixture`；该模式下等效修复是在场景文件中声明 `fixtures`，提示文案本身不随模式变化。

### 3.5 模拟 Dock 与悬停

启动器右栏的模拟 Dock 用于在缺少真实系统依赖时观察插件在 Dock 预览中的样子；它复用宿主渲染组件与插件会话，但窗口、图标和缩略图均为模拟数据。

- **图标与数据来源**：底部一排 Dock 图标中，目标应用图标由 `manifest.matches` 首项（自定义模式为 `target.bundleID`）解析系统图标；解析不到时使用占位图标。另放 1–2 个固定占位图标；只有目标应用图标响应悬停，固定占位图标不弹出浮层。
- **触发与计时**：鼠标真实悬停目标应用图标后延迟 0.4 秒显示浮层；指针离开时保留 0.3 秒宽限再隐藏；在图标之间切换时立即更新，不重新等待显示延迟。计时只作用于模拟 Dock，不证明本体 Dock 的触发延迟与宽限行为。
- **定位**：浮层从目标图标上方居中弹出，并限制在右栏可见范围内；右栏空间不足时不越出右栏。
- **浮层结构**：与本体 Dock 预览一致的“面板壳（标题头 + 窗口条）”加目标应用的模拟窗口卡片。窗口卡片使用固定示例标题与占位缩略图，交通灯按钮只作展示（close/minimize/zoom 不可操作，也不调用 AX）。
- **槽位挂载（以 `Sources/Views/DockPreviewView.swift` 为准）**：
  - `center`：挂载在窗口条之后、窗口卡片区下方，是一个独立的插件卡片；窗口为空且存在 center 内容时替代空状态。它不在单张窗口卡片内部。
  - `bottomBar`：覆盖首张窗口卡片缩略图的底部，只挂到第一张卡。
  - `topTrailing`、`titleAccessory`：本体 Dock 尚未接入这两个槽位；模拟 Dock 不展示其内容，也不因此改变“只渲染未接入槽位”的既有判定（契约 §1）。
- **交互**：浮层内插件控件按正常会话处理，按钮等动作真实触发 `onAction` 并走插件会话；重置、重渲染和错误提示与左栏控制区共享同一草稿状态。
- **限制**：模拟 Dock 不枚举真实窗口、不读取真实应用图标之外的系统状态、不截图，也不验证 Dock 命中区域、AX 悬停、跨屏定位、真实窗口缩略图或桌面玻璃合成。原始桌面透射模式下的玻璃外观取决于实时桌面，**不得**作为视觉基线；任何需要真实窗口、AX 或屏幕合成的结论仍由本体取证。

## 4. 版本握手

预览 App 提供 `--version-json`（无 GUI、无网络）：`tool`、`toolVersion`、`protocolVersion`、`scenarioSchemaVersion`、`pluginAPIVersions`、`sdkContractHash`、`rendererRevision`、`architecture`。CLI 在启动预览前核对：`protocolVersion`、`scenarioSchemaVersion` 与 CLI 要求一致，`toolVersion` 主版本一致，`sdkContractHash` 等于 CLI 随包契约文件的哈希，插件 `apiVersion` 在 `pluginAPIVersions` 内。不一致返回 `incompatible-preview-tool`（4，`error.details.mismatches` 列出字段）或 `plugin-api-unsupported`（3）；工具不支持 `--version-json`、超时（5 秒）、输出无效或超过 16 KiB 同样拒绝。worker 握手在执行任何 JS 前再次核对同样的字段。

## 5. worker 帧与生命周期

传输为四字节无符号大端长度加 UTF-8 JSON；每帧上限复用 `PluginPackageValidator.maxPackageBytes`（32 MiB）。空帧、无效 UTF-8/JSON、截断、超限或不支持协议版本均为协议错误；接收端最多缓存一个未完成帧；worker 同一时刻只处理一个变更请求，控制器最多排队一个请求并合并 invalidate。

帧对象：`protocolVersion: 1`、`type`、`generation`、`requestID`、`payload`。请求：`hello`、`load`、`render`、`action`、`advance`（仅场景声明 `clock` 时可用，单次 ≤ 24 小时）、`suspend`、`resume`、`unmount`、`shutdown`、`storageDump`；响应携带同一 generation/requestID；worker 可发 `invalidate` 事件，事件仅属于当前 generation。Runtime 输出仍通过宿主 `PluginRenderOutput.decode` 校验，GUI 以同一解码器解码。worker 以白名单环境启动；stdout 专用于帧，stderr 只输出固定诊断，插件 `console` 与宿主日志默认被抑制：worker 只在内存里缓冲最近 200 行 `console`（每行 ≤ 500 字符），仅当 `render` / `action` / `advance` 请求带 `includeConsole: true` 时才随响应的 `consoleLines` 回传并清空缓冲；只有 GUI 启动器的调试面板会发这个标志，CLI、`dev` 与场景运行从不请求，因此不产生任何 console 输出，也不落盘。控制器为启动、每次执行和关闭设置 watchdog，超时先终止、必要时强杀并等待回收；错误 generation 的返回、动作和 invalidate 被丢弃。`dev` 重载：新包完整复制并校验后切换 generation；失败保留旧画面并标为 stale；内容与当前世代一致时不产生新世代。关闭时停止 watcher、timer、管道和子进程；向 CLI 发送 `SIGINT`/`SIGTERM`/`SIGHUP` 会转发给预览进程，10 秒后升级为 `SIGKILL`。

## 6. 视觉基线

逻辑身份是「插件 ID + 场景 ID」；包哈希只作溯源。只有 `deterministicClock` 为真且 `glass` 为假的 `passed` 运行可被 `baseline accept`。兼容指纹为：系统主版本、架构、`displayScale`、`rendererRevision`、`toolVersion`、语言、外观；任一不同则 `baseline compare` 拒绝比较（`incompatible-environment`，退出 4）。比较默认零容差，`--tolerance` 必须显式给出并记录。尺寸变化为 `size-changed`，像素差异为 `visual-diff`，并输出 `diff.png`。基线图片与 `baseline.json` 的哈希不一致视为被篡改（`baseline-invalid`）。

## 7. 可执行的冻结点

| 项 | 常量位置 | 校验 |
| --- | --- | --- |
| 契约哈希：`Plugins/api/` 下 6 个契约文件 | `PluginPreviewContract.sdkContractHash` | `Tools/PluginPreview/contract-hash.sh --check` |
| 渲染器 revision：12 个共享渲染源文件 | `PluginPreviewContract.rendererRevision` | `Tools/PluginPreview/renderer-revision.sh --check` |
| 共享源码守卫 | — | `Tools/PluginPreview/shared-source-check.sh` |

三者均并入 `make plugin-preview-contract-check`。更改 Schema 或共享渲染源文件后，必须更新常量并重新接受视觉基线。CLI 与预览工具必须同版本发布（`package-toolkit.sh` 校验）。

## 8. 当前限制

2.1–2.3、3.1–3.5 描述的默认场景、覆盖项、`inspect`、GUI 启动器/自定义模式、两栏启动器与模拟 Dock、内置样例与缺数据提示**实现中**，其验收以 `Tests/PluginPreview/` 回归为准；本文先冻结形状与规则，未验证项不视为通过。内置样例资源、`fixtures[].source`、GUI 的“清除即不可用”行为和可访问标签尚无实机证据。

旧系统（macOS 12）、原生 Intel 硬件与无图形会话仅验证了逻辑分支，未在对应环境实测；fixture 更新类步骤未实现；滑块、hover、键盘焦点未覆盖。GUI 启动器的拖入目录、最近使用、导出场景与自定义控件交互尚无完整实机回归。2026-11-05 已在 1080×720 启动器窗口实际检查两栏布局、控制区收窄、默认舞台、英文/简体中文文案与原始桌面透射；<900 pt 纵向堆叠、模拟 Dock 的 0.4 s/0.3 s 悬停计时、浮层定位与槽位挂载仍无完整回归证据。模拟 Dock 在原始桌面透射模式下的玻璃外观依赖实时桌面，不作为视觉基线；真实 AX 悬停、跨屏、真实缩略图与桌面玻璃合成仍由本体验证。详见 [覆盖矩阵](plugin-preview-coverage.md)。
