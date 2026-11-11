# 插件独立预览：开发者与 Agent 使用指南

状态：本地候选（工具版本 0.1.0）；默认场景、覆盖项、`inspect` 与 GUI 启动器改造**实现中**，以 `Tests/PluginPreview/` 回归为准。本文所有标注为 `quickstart` 与 `agent-loop` 的命令块由 `Tests/PluginPreview/run-guide-check.sh` 从本文原样提取并在最终工具包上执行；其余命令与退出码以 `Tests/PluginPreview/` 下的回归脚本为准。契约见 [插件独立预览契约](plugin-preview-contract.md)，覆盖范围与未验证项见 [覆盖矩阵](plugin-preview-coverage.md)。

## 1. 它能做什么，不能做什么

在 **Switchly 本体未运行** 的情况下，用与本体同一份 Runtime、解码器和渲染代码，预览插件、执行动作、导出截图与报告。

| 能做 | 不能做（仍由本体验证） |
| --- | --- |
| 用合成的媒体/天气/文件数据渲染插件，导出 `report.json`、`preview.png`、`ui-tree.json`、`actions.json` | 真实 Dock 悬停、Accessibility 切窗、跨屏、真实窗口缩略图、桌面玻璃合成 |
| 场景步骤：推进虚拟时间、触发动作、断言文本、经可访问树点击控件 | 真实媒体控制、真实网络天气、读取你的真实目录 |
| 固定时钟下的逐像素视觉基线与差异图 | 滑块调节、键盘焦点（尚未覆盖）；启动器模拟 Dock 的 hover 只模拟展示，不验证本体 Dock |
| 启动器两栏内用模拟 Dock 观察插件在 Dock 预览浮层中的样子并真实触发插件动作 | 把模拟 Dock 当作真实 Dock 命中/AX/跨屏/玻璃的验证；原始桌面透射下的玻璃外观依赖桌面背景，不能作基线 |

本次改造后，日常预览不再必须先写场景文件：工具从 manifest 推导默认场景，可用覆盖项调整语言/外观/宽度/目标/授权/设置/fixture；默认场景对媒体和天气**开箱即用**——声明了任一媒体权限（`media.nowPlaying`/`media.control`/`media.library`）的插件自动带内置合成媒体样例，声明 `weather.current` 的自动带内置合成天气样例；`fs.read` 因内容取决于插件自身目录，仍需显式文件。`inspect` 可在无 GUI 下查看推导结果与 fixture 来源；GUI 启动器提供插件选择、默认/自定义模式、“导出为场景文件”，并在右栏用模拟 Dock 展示插件在 Dock 预览浮层中的样子。这些能力**实现中**，验收以 `Tests/PluginPreview/` 回归为准。

## 2. 前置条件

- macOS 12 或更新；Node.js 18 或更新。
- `run` 需要截图：图形会话 + 系统设置里授予运行预览的终端/应用「屏幕录制」权限。不可用时命令返回环境错误（退出码 4），**不会**伪造通过。
- Agent 可给 `run` 加 `--background` 做后台视觉与输入验证：预览 App 不激活、不打开工作台；截图表面使用从不排序到屏幕的原生 nonactivating 面板，输入和截图复用同一共享 Renderer。支持标签 `nativeClick` 与 3D 坐标点击／拖动；不发送全局键鼠事件。每次执行先做有效图像与隔离自检，失败退出 4，不回退显示窗口。仍需图形会话及屏幕录制权限；跨系统兼容性以实测为准。
- 不需要 Xcode，不需要联网，不需要 Switchly 本体在运行。

## 3. 取得并安装工具包

工具包是一个 `switchly-plugin-preview-toolkit-<版本>.tar.gz`（含预览 App、CLI 的 npm tarball、`toolkit-manifest.json`、`SHA256SUMS`）。当前为**本地候选**：ad-hoc 签名，未做 Developer ID 签名与公证，也没有发布到 npm。

维护者在 Switchly 仓库生成它：

```sh
make plugin-preview-package          # 产物在 DerivedData/PluginPreviewRelease/toolkit/
```

作者拿到 tar.gz 后：

```sh
shasum -a 256 -c switchly-plugin-preview-toolkit-0.1.0.tar.gz.sha256
tar -xzf switchly-plugin-preview-toolkit-0.1.0.tar.gz
```

CLI 与 App 必须来自**同一个**工具包。版本、协议或契约哈希不一致时，CLI 在启动预览前拒绝并说明哪一项不一致（退出码 4，错误码 `incompatible-preview-tool`）。

## 4. 快速开始

下面的块从零开始：离线安装 CLI、创建插件、校验、查看推导场景，再用覆盖项运行。**不需要场景文件**；`create` 默认渲染到 `center`（可截图）。运行前设置 `KIT` 为解包后的工具包目录。

```bash quickstart
: "${KIT:?请把 KIT 设置为解包后的工具包目录}"
mkdir -p hello-project && cd hello-project
npm init -y >/dev/null
npm install --offline --no-audit --no-fund "$KIT"/switchly-plugin-cli-*.tgz >/dev/null

# create 生成最小插件，默认渲染到 center；不再需要手写 main.js。
npx --no-install switchly-plugin create ./hello --id com.example.hello --name Hello --match com.example.app >/dev/null
npx --no-install switchly-plugin validate ./hello

# 查看 manifest 推导出的默认场景、设置项，以及 fixture 需求与来源（source）。
npx --no-install switchly-plugin inspect ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --json > inspect.json
node -e 'const d = JSON.parse(require("fs").readFileSync("inspect.json", "utf8")); if (d.defaultScenario?.id !== "default" || d.defaultScenario.target.bundleID !== "com.example.app") { console.error(d); process.exit(1); } console.log("default scenario:", d.defaultScenario.id, d.defaultScenario.target.bundleID);'

# 覆盖项直接运行：中文、深色；不需要 --scenario。
npx --no-install switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --locale zh-Hans --appearance dark --out out --background --json > result.json
node -e 'const r = JSON.parse(require("fs").readFileSync("result.json", "utf8")); if (r.status !== "passed" || r.scenarioSource !== "derived") { console.error(r); process.exit(1); } console.log("status:", r.status, "source:", r.scenarioSource);'
```

读结果：`out/report.json`（状态、场景来源、环境指纹、逐步 trace）、`out/preview.png`（截图）、`out/ui-tree.json`（经宿主解码器验证的原始声明式树）、`out/actions.json`（可用动作与启用状态）。**打开 `preview.png` 看一眼**：退出码 0 只说明渲染成功，不说明画面是你想要的。

### 4.1 默认场景与覆盖项

未给 `--scenario` 时，工具从 manifest 推导场景：`id` 为 `default`，英文/浅色/非玻璃/减少动态效果/360 pt，目标取 `matches` 首项，授权取 manifest 全部权限，固定时钟 `1700000000000/seed 1`，不提供步骤。fixture 按权限自动选择：

- 声明 `media.nowPlaying`、`media.control`、`media.library` 任一 → 内置合成媒体样例（曲名 `Synthetic Evening`、艺人 `Fixture Ensemble`）。
- 声明 `weather.current` → 内置合成天气样例。
- 声明 `fs.read` → **不内置**；内容取决于插件自身目录，需要 `--fixture fs=<文件>` 或 GUI 选择文件，否则该能力不可用。

内置样例随预览 App 资源分发，是明显的合成数据，不读取任何真实系统数据。因此默认运行是确定性的，可直接用于视觉基线；fixture 来源不进入基线身份。

fixture 的覆盖与清除：

- `--fixture media=<文件>` / `weather=<文件>` / `fs=<文件>` 覆盖对应内置样例。三种 kind 都必须给出显式文件，没有不带文件的裸开关。
- GUI 自定义模式同样可“选择文件…”覆盖；点「清除 / Clear」表示该能力**不可用**，不会回退到内置样例，用于测试插件的降级路径。
- 显式 `--scenario` 的语义不变：场景文件没有声明 `fixtures` 就是不可用，不会自动附加内置样例；导出为场景文件时，内置样例会被复制到导出目录并以相对路径引用。

常用覆盖项（与 App 参数同名；给出 `--scenario` 时再给任何覆盖项会以退出码 2 拒绝）：

```sh
switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --out out --json \
  --locale zh-Hans --appearance dark --no-glass --width 320 \
  --target-bundle-id com.example.other --target-app-name Other
```

`--grants none` 或 `--grants media.nowPlaying,weather.current` 显式替换默认的全授权；`--set key=value` 可重复（同一 key 只能一次），值按 manifest 设置类型解析；`--fixture media=<文件>`、`--fixture weather=<文件>`、`--fixture fs=<文件>` 均为显式文件，覆盖同名内置样例。完整规则见 [契约 §2](plugin-preview-contract.md#2-场景)。玻璃运行不能作基线。

## 5. 场景文件（进阶：断言与回归）

日常预览优先使用默认场景加覆盖项（§4.1）。只有以下情况才需要显式场景文件：需要 `steps` 做文本断言或原生点击、需要 `storageSeed`、需要精确控制 `clock` 的起点/随机种子、需要为视觉基线固定一个独立的场景 ID，或要把整套输入随仓库一起做回归。显式场景也是 `--scenario` 的唯一输入形式；它与覆盖项互斥。

场景是开发用的输入，与发布包的 manifest 分离。未知字段会被拒绝（`invalid-scenario`）。fixture 写在场景里时，路径相对场景文件所在目录；用 `--fixture` 时由工具复制文件并改写为相对路径。

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 整数 `1` |
| `id` | 场景 ID；与插件 ID 一起构成视觉基线的逻辑身份 |
| `environment` | `locale`（`en`/`zh-Hans`）、`appearance`（`light`/`dark`）、`glass`、`reduceMotion`、`contentWidthPoints` |
| `target` | `bundleID`、`appName`，可选 `titleSummary`、`lastActiveAt` |
| `fixtures` | `media`/`weather`/`fs`：相对场景目录的 JSON 文件路径，不得越界或是符号链接；缺省表示该能力不可用，**不会**读取真实系统数据，也不会自动套用内置样例（内置样例只用于推导场景） |
| `grants` | 授予的权限，与 manifest 声明取交集（超出 manifest 的部分被忽略） |
| `settings` / `storageSeed` | manifest 设置键到合法值的映射 / 初始私有存储 |
| `clock` | `{ "startEpochMs", "seed" }`：JS 的 `Date`、`Math.random`、`setTimeout` 与 Scene 绘制时刻都使用虚拟时间，仅在 `advance` 步骤时前进。缺省为实时 |
| `steps` | 最多 64 个，见下表；缺省或空数组表示只渲染一次 |

槽位：`center`、`bottomBar` 与本体 Dock 一致且会被截图；`topTrailing`、`titleAccessory` 本体 Dock 尚未接入，只渲染而**不截图**——只渲染这两个槽位的插件会得到 `unsupported` / `no-capturable-slot`（退出码 3）。

### 步骤

| `type` | 字段 | 作用 | 证据来源 |
| --- | --- | --- | --- |
| `advance` | `ms`（0–86 400 000） | 推进虚拟时钟并触发到期定时器；**需要场景声明 `clock`** | `clock` |
| `action` | `id`、可选 `value` | **业务动作**：直接调用插件 `onAction`。不证明控件可点击 | `business-action` |
| `expectText` | `contains` | 渲染树的任一文本包含该字符串 | `render-output` |
| `nativeClick` | `label`，可选 `expectAction` 或 `expectDisabled: true`（互斥） | **原生输入**：经可访问树按标签 press，并核对动作确实路由到会话；`expectDisabled` 要求控件存在、禁用且没有动作被触发 | `native-input` |
| `nativeClickAt` | `point: {x,y}`，可选 `expectAction` | 截图表面左上角的逻辑点，经 hitTest 命中真实 SceneKit 视图，调用原生鼠标 down/up；核验回调及 worker 结果 | `native-input` |
| `nativeDrag` | `from: {x,y}`、`to: {x,y}` | 同一表面内的真实 SceneKit 视图拖动，8 段、约 160ms；不要求产生业务动作 | `native-input` |

坐标必须有限、非负且在当前截图表面内；截图是像素，输入是逻辑点，须除以报告的 `environment.displayScale`。坐标输入仅适配 SceneKit，命中其他视图返回 `pointer-target-unsupported`；超出表面返回 `point-out-of-bounds`。它不是系统鼠标操作，也不证明 Agent 已自主定位任意控件。后台标签输入用只读 helper 初始化自身 AX 树，不读取其他应用、不写 focus。后台与最终捕获对同一活视图操作，动作后重新布局并取图；不能用业务 `action` 代替原生输入证据。

步骤按顺序执行，**首个失败即停止**，其后步骤记为 `skipped`，整体状态 `failed`、错误码 `step-failed`，且不产生截图（不会出现「失败但有一张好看的图」）。每步 trace 只含固定失败码，不回显断言文本或渲染内容。

## 6. 结果与退出码

`--json` 时 stdout **只有一个 JSON 对象**，诊断一律在 stderr。`status` 之外，结果对象含 `scenarioSource`（`derived` 表示使用推导场景，`file` 表示给了 `--scenario`）；`report.json` 同样记录该字段。

| 退出码 | `status` | 含义 |
| --- | --- | --- |
| 0 | `passed` | 渲染与全部步骤通过，产物完整 |
| 1 | `failed` | 插件或场景有问题（见下表） |
| 2 | — | 命令行参数错误 |
| 3 | `unsupported` | 使用了尚不支持的能力（槽位未接入、未知步骤类型、插件 API 超出工具支持范围） |
| 4 | `environment-error` | 环境问题：无图形会话/屏幕录制授权、工具与 CLI 不配套、找不到预览工具 |

> 脚本与 Agent 把 4 视为「没跑成」而不是「通过」；GUI 回归脚本在环境不可用时退出 77，CI 按失败处理。

## 7. 错误修复

常见失败由 `Tests/PluginPreview/run-failure-modes-tests.sh` 验证；后台输入的步骤错误与隔离由 `run-background-input-tests.sh` 验证。隐藏捕获不可用的历史反例见 PV-D13，新后台路径每次运行均做图像自检。

| 现象（`error.code` / `failure.code`） | 原因 | 修复 |
| --- | --- | --- |
| `background-surface-unavailable`（4） | 隐藏原生表面不可捕获、图像全透明／单色、helper 不可用或捕获前后隔离校验失败 | 在有授权的 GUI 会话核验该系统兼容性；不回退前台，不将环境错误记为通过 |
| `no-capturable-slot`（3） | 插件只渲染了 `topTrailing`/`titleAccessory` | 渲染到 `center` 或 `bottomBar` |
| `empty-render`（1） | `render` 返回空数组 | 在目标应用匹配时返回至少一个槽位内容 |
| `plugin-script-error`（1） | `render` 抛出异常，也包括 manifest 需要但没有任何来源的 fixture（如 `fs.read` 未给文件、GUI 已清除内置样例） | 在插件里修复；用 `console.log` 不会输出到预览（日志被刻意抑制）。缺 fixture 时按下面的固定提示补齐数据 |
| `invalid-render-output`（1） | 返回的 UI 不符合声明式树契约 | 对照 [API 参考](../plugin-api-reference.md) §7 |
| `plugin-timeout`（1） | 渲染超时（如死循环）；worker 已被终止并回收 | 去掉死循环或阻塞逻辑 |
| `invalid-package`（1） | manifest 损坏、入口缺失或超出包限制 | 先运行 `switchly-plugin validate` |
| `invalid-scenario`（1） | 场景含未知字段或非法值 | 对照第 5 节 |
| `invalid-fixture`（1） | fixture 缺失、过大、越界或与插件根目录不匹配 | 检查 `fixtures` 路径与内容 |
| `invalid-grants` / `invalid-settings`（1） | 授权或设置不符合 manifest | 对照 manifest 的 `permissions` 与 `settings` |
| `step-failed`（1） | 某个步骤失败 | 看 `report.json` 的 `steps`，失败项的 `detail` 是固定码（`text-not-found`、`action-unavailable`、`action-disabled`、`action-ambiguous`、`element-not-found`、`element-disabled`、`wrong-action-routed`、`no-action-routed` 等） |
| `unsupported`（3） | 未知步骤类型 | 只使用第 5 节列出的步骤 |
| `plugin-api-unsupported`（3） | 插件 `apiVersion` 超出工具支持范围 | 升级工具包或调整 `apiVersion` |
| `incompatible-preview-tool`（4） | CLI 与 App 不配套 | 使用同一工具包；`error.details.mismatches` 列出不一致项 |
| `environment-unavailable`（4） | 无图形会话或无屏幕录制授权 | 在有 GUI 的会话运行并授权 |
| `output-not-empty`（2） | `--out` 目录非空 | 换一个空目录（CLI 不会覆盖已有产物） |

当渲染失败且 manifest 需要的某个 fixture 没有来源时，错误码仍是 `plugin-script-error`（退出码 1），但提示固定指向修复：`该插件需要 <kind> fixture，请在自定义模式选择文件，或使用 --fixture <kind>=<文件>`。GUI 窗口、`run` 的 `error.message` 与 `report.json` 的 `failure.message` 使用同一文案，不含本机路径。显式 `--scenario` 模式下不能叠加 `--fixture`，应在场景文件的 `fixtures` 里声明文件。

本次改造新增的参数错误（覆盖项与 `--scenario` 同用、取值非法、同一 fixture kind 重复）同样以退出码 2 拒绝，错误码 `invalid-arguments`；该分支的回归在实现落地后补入 `Tests/PluginPreview/`，当前不作为已验证项。

## 8. 权限降级

- `grants` 与 manifest 的 `permissions` 取交集；场景里多授予的权限被忽略（不会因此失败）。
- 没有提供对应 fixture 的能力表示**不可用**：插件应处理 `ctx.capabilities[...]`.available 为 false 的降级路径。推导默认场景会为声明了媒体权限的插件提供内置媒体样例、为 `weather.current` 提供内置天气样例；`fs.read`、显式场景和 GUI 清除后的能力仍需文件或保持不可用。预览永远不会去读取真实媒体、网络或用户目录。
- `window.focus`、`appleScript` 在预览中标记为不支持。

## 9. 视觉基线

只有**确定时钟且非玻璃**的 `passed` 运行才能作为基线（玻璃截图依赖桌面背景，只能当证据）。默认场景自带固定时钟、`id` 为 `default`，可直接作基线；`scenarioSource`（`derived`/`file`）不参与基线身份，身份始终是「插件 ID + 场景 ID」，所以默认场景与显式场景不会互相覆盖。

```sh
# 接受：显式操作；已存在时必须再加 --replace
switchly-plugin baseline accept out --baseline-dir baselines
# 比较：默认零容差；--tolerance 0-255 必须显式给出并记录在报告里
switchly-plugin baseline compare out2 --baseline-dir baselines --out cmp --json
```

`cmp/compare-report.json` 给出差异像素数、比例、最大通道差与包围盒，`cmp/diff.png` 把变化标红、其余压暗。基线的逻辑身份是「插件 ID + 场景 ID」，包哈希只作溯源字段；系统主版本、架构、显示缩放、渲染器 revision、工具版本、语言或外观不同则**拒绝比较**（退出码 4，`incompatible-environment`，列出不一致字段）。更新基线是显式动作：确认变化符合预期后 `baseline accept ... --replace`。工具不会自动接受基线，也不会通过放宽阈值让检查变绿。

## 10. dev 模式

```sh
switchly-plugin dev ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --locale zh-Hans --appearance dark
# 需要断言或精确控制时再显式给场景：
switchly-plugin dev ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --scenario scenario.json
```

打开原生预览窗口；`--scenario` 可选，覆盖项与 `run` 相同。保存文件会整包重新校验并换代；失败（如 manifest 损坏）保留旧画面并标为 stale，修好后再次保存即恢复；内容与当前世代完全一致时不产生多余的新一代。窗口隐藏时暂停受控定时器。关闭窗口或向 CLI 发送 `SIGINT`/`SIGTERM` 会终止预览 App 与 worker，不留孤儿进程。

## 11. GUI 使用

双击 `SwitchlyPluginPreview.app`（或 `open -a "$KIT/SwitchlyPluginPreview.app"`）。不带参数启动时是启动器：不加载插件，窗口先要求选择插件目录。`switchly-plugin dev` 仍打开原有的插件预览窗口，不受启动器改版影响。

**两栏布局**：启动器窗口分为左右两栏。左栏是较窄的不透明控制区，集中插件选择（打开/拖入/最近使用）、默认/自定义模式、场景各项设置、fixture、导出场景与诊断；右栏是带标题的模拟 Dock 工作台舞台。窗口宽度小于 900 pt 时两栏改为纵向堆叠（控制区在上，模拟 Dock 在下）。

工作台舞台默认使用明确的舞台背景。舞台标题栏的“原始桌面透射 / Raw desktop”开关可移除舞台和标题栏底色，让整块右栏透出实时桌面，用于检查玻璃材质对真实背景的采样；该模式只作观察，不能作为视觉基线。调试面板默认收起，展开后会加宽窗口而不会挤压舞台。

**选择插件**：点「打开插件目录…」用 `NSOpenPanel` 选目录，或把目录拖进窗口；最近使用最多 8 条，保存在预览 App 自己的 `UserDefaults`。

**默认 / 自定义**：

- 「默认」：使用 manifest 推导场景，控制区只读展示当前值，标注“推导的默认场景 / Derived default scenario”。fixture 区显示推导将使用的来源，如 `Fixtures: 内置样例（media, weather） / Built-in samples (media, weather)`；需要 `fs` 时标注“需显式文件 / Needs a file”，没有来源时显示“无 / None”。想快速看插件在标准环境下的样子时用它。
- 「自定义」：改动任一控制项立即重建会话并重渲染（同时重置该会话存储）。失败只显示在窗口内，不退出。选中 fixture 文件会覆盖内置样例；点「清除 / Clear」表示该能力不可用，不会回退到内置样例。渲染失败且缺少所需 fixture 时，窗口内显示 §7 的固定修复提示。
- 所有可交互控件（「打开插件目录… / Open Plugin Directory…」、模式切换、各编辑控件、fixture 的“选择文件…/清除”）都有可访问标签，供辅助技术与 `nativeClick` 识别；不以颜色或位置替代标签。

**自定义控件与 CLI 对照**：

| GUI 控件 | CLI 覆盖项 | 场景字段 |
| --- | --- | --- |
| 语言（en / zh-Hans） | `--locale` | `environment.locale` |
| 外观（light / dark） | `--appearance` | `environment.appearance` |
| 玻璃开关 | `--glass` / `--no-glass` | `environment.glass` |
| 减少动态效果 | `--reduce-motion` / `--no-reduce-motion` | `environment.reduceMotion` |
| 内容宽度 | `--width` | `environment.contentWidthPoints` |
| 目标 bundleID / 名称 | `--target-bundle-id` / `--target-app-name` | `target.bundleID` / `target.appName` |
| 权限授予（manifest 声明项逐个开关） | `--grants` | `grants` |
| manifest 设置项（toggle / 选项 / 滑块） | `--set key=value` | `settings` |
| fixture（media / weather / fs：选择文件覆盖内置样例；清除表示不可用） | `--fixture media=<文件>`、`--fixture weather=<文件>`、`--fixture fs=<文件>` | `fixtures` |
| 虚拟时钟固定开关、`+1s`/`+1min`/自定义毫秒 | 无覆盖项；用显式场景文件 | `clock`（推进只作用于当前会话） |

**模拟 Dock 与悬停**：右栏底部有一排 Dock 图标。目标应用图标用 `manifest.matches` 首项（自定义模式用你填的 bundleID）解析系统图标，解析不到时显示占位图标；旁边另有 1–2 个固定占位图标，只有目标应用图标响应悬停。鼠标真实悬停目标图标 0.4 秒后，从图标上方居中弹出浮层，并限制在右栏内；指针离开后保留 0.3 秒宽限再隐藏，在图标间切换时立即更新。浮层结构与本体 Dock 预览一致：标题头、窗口条、目标应用的模拟窗口卡片（固定示例标题、占位缩略图，交通灯只作展示、不可操作），并按本体 `Sources/Views/DockPreviewView.swift` 的规则挂载插件槽位：

- `center` 挂在窗口条之后、窗口卡片区下方，是独立插件卡片；不在单张窗口卡片内部。
- `bottomBar` 覆盖首张窗口卡片缩略图的底部。
- `topTrailing`、`titleAccessory` 本体 Dock 尚未接入，模拟 Dock 不展示其内容。

浮层里的插件按钮等控件可以真实点击并走插件会话，和左栏的草稿状态一致。**模拟 Dock 不是本体 Dock 悬停的验证**：它不枚举真实窗口、不截取真实缩略图，也不验证 Dock 命中区域、真实 AX 悬停、跨屏定位或桌面玻璃合成；这些仍须在本体取证。

**导出场景**：点「导出为场景文件…」，选择保存位置。当前草稿写成合法场景 JSON；显式 fixture 与内置样例都作为文件复制到同一目录并用相对路径引用；写出后用 `PreviewScenario.decode` 回读校验。导出的文件可直接交给 `--scenario`，此时 `scenarioSource` 为 `file`，且不再依赖预览 App 资源。

**边界**：启动器改造当时只改启动器窗口；后续 PV-D06 新增显式 `run --background`，默认 `dev`/`run` 行为与基线身份未变。启动器里的模拟 Dock 只复用宿主渲染与插件会话，不替代真实 Dock 验证——真实 AX 悬停、跨屏、真实缩略图与桌面玻璃合成仍由本体承担。GUI 启动器、两栏布局、模拟 Dock 悬停与浮层、拖入目录、最近使用、fixture 的内置/覆盖/清除、缺数据提示、导出流程与可访问标签在本次改造中**实现中**，以 `Tests/PluginPreview/` 回归为准。

## 12. Agent 无 GUI 流程

Agent 不需要打开 GUI 启动器，也不必人工点选；以下截图流程显式使用 `--background`，仍需要图形会话与屏幕录制授权（`inspect` 不需要）。场景可包含 `nativeClick`、`nativeClickAt` 或 `nativeDrag`；后台回归入口为 `make plugin-preview-background-test`，可用 `PLUGINS_REPO` 指定包含 iPod 与合成媒体夹具的外仓。

仓库封装 `Scripts/plugin-preview.sh run`（`mise run preview:run`）自动添加 `--background`，与其“无界面运行”约定一致；直接调用 CLI 时须显式传入该参数。

1. **查看默认输入**：`inspect` 输出插件信息、推导场景、设置项和 fixture 的 `needed`/`reason`/`source`。`source: builtin` 表示 media/weather 会自动使用内置样例；`fs.read` 即使 `needed: true` 也通常是 `source: none`，需要显式文件。据此决定要不要覆盖。
   ```sh
   switchly-plugin inspect ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --json > inspect.json
   ```
2. **直接运行**：用覆盖项表达环境差异，`--json` 只解析 stdout 的单个对象。声明了媒体/天气权限的插件默认即可运行（内置样例）；`fs.read` 需要额外加 `--fixture fs=<文件>`，文件内容要匹配插件自身的目录结构。
   ```sh
   switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" \
     --locale zh-Hans --appearance dark --out out-agent --background --json > result.json
   ```
3. **读产物**：先看 `result.json` 的 `status`/`scenarioSource`，再读 `out-agent/report.json`（环境指纹与 trace），**打开 `out-agent/preview.png`** 判断画面；`ui-tree.json` 与 `actions.json` 用于核对声明式树和可用动作。
4. **分流失败**：退出码 1 读 `error.code` 或 `report.json.failure.code`，按 §7 修复后换新的空 `--out` 重跑；若 `plugin-script-error` 且提示“该插件需要 <kind> fixture…”，优先补齐对应 fixture（默认模式加 `--fixture <kind>=<文件>`；显式场景则改场景文件的 `fixtures`）再重跑。3 是能力边界，不重试；4 是环境问题，停止并报告，不能当成通过。
5. **需要断言时**：写显式场景文件（§5），用 `--scenario` 运行；此时不能再叠加覆盖项。

## 13. Agent 使用约定

1. 始终使用 `--json`，只解析 stdout 的**单个** JSON 对象；不要解析 stderr（只有固定诊断）。
2. 以退出码分流：`0` 成功；`1` 去读 `error.code` 或 `report.json` 的 `failure.code` 与 `steps`，修改插件或场景后重跑；`3` 是能力边界，不要重试；`4` 是环境问题，停止并报告，**不要把它当成通过**。
3. 每次运行用**新的空** `--out` 目录。
4. 退出码 0 之后仍要读 `preview.png` 判断画面是否符合预期；断言文本只能证明「有这段文字」。
5. 区分证据：`action` 是业务直调；`nativeClick` 经过控件与可访问标签，`nativeClickAt`／`nativeDrag` 经过真实 SceneKit 视图的鼠标处理。它们都不能替代本体里的真实 Dock 验证。

下面的循环块同样被原样执行：用显式场景文件（进阶/回归用法）注入断言，失败时把 `step-failed` 的失败步骤找出来，演示「运行 → 解析 → 判断 → 修复 → 重跑」。运行前设置 `KIT`，并在 `quickstart` 之后的同一目录执行。

```bash agent-loop
: "${KIT:?请把 KIT 设置为解包后的工具包目录}"
cd hello-project

# 进阶/回归：默认场景没有 steps，这里显式写一个带断言的文件。
cat > scenario.json <<'JSON'
{
  "schemaVersion": 1,
  "id": "agent-check",
  "environment": { "locale": "en", "appearance": "light", "glass": false, "reduceMotion": true, "contentWidthPoints": 360 },
  "target": { "bundleID": "com.example.app", "appName": "App" },
  "clock": { "startEpochMs": 1700000000000, "seed": 1 },
  "steps": [{ "type": "expectText", "contains": "Goodbye" }]
}
JSON

run_preview() { # 输出目录名
  npx --no-install switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" \
    --scenario scenario.json --out "$1" --background --json 2>/dev/null
}

# 故意让断言失败：示例插件不会渲染这段文字。
# 注意：在 set -e 下，$(...) 失败会让脚本立刻退出，必须用 && / || 捕获退出码。
result=$(run_preview agent-fail) && code=0 || code=$?
[ "$code" -eq 1 ] || { echo "期望退出码 1，实际 $code"; exit 1; }
failed_step=$(printf '%s' "$result" | node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); const f = r.steps.find((s) => s.status === "failed"); console.log(r.failure.code + " " + f.index + " " + f.detail);')
[ "$failed_step" = "step-failed 0 text-not-found" ] || { echo "意外的失败信息：$failed_step"; exit 1; }
echo "诊断：$failed_step"

# 修复（把断言改回插件实际渲染的文本）后重跑，必须通过。
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync("scenario.json", "utf8")); s.steps[0].contains = "Ready"; fs.writeFileSync("scenario.json", JSON.stringify(s));'
run_preview agent-pass >/dev/null && code=0 || code=$?
[ "$code" -eq 0 ] || { echo "修复后期望退出码 0，实际 $code"; exit 1; }
echo "修复后通过"
```

## 14. 已知限制

- 工具包是本地候选：未做 Developer ID 签名与公证，未发布 npm；通过浏览器下载的副本会被 Gatekeeper 隔离。
- 已实测架构：arm64 原生与 x86_64（Apple Silicon 上经 Rosetta）；原生 Intel 硬件与 macOS 12 未验证。
- 新后台表面目前只在本机 arm64／macOS 27.2 验证；旧系统、原生 Intel、跨 Space 与压力矩阵未完成。隐藏窗口捕获没有跨版本稳定保证，须逐次通过图像自检。原生玻璃用于观察，不保证与已显示表面逐像素等价；真实相机与 SwiftUI 动画不受 JS 固定时钟完整控制，不能据此声称严格同帧回放。
- 未覆盖：滑块调节、hover、键盘焦点；窗口隐藏/最小化触发的 `suspend`/`resume` 自动化；fixture 更新类步骤。
- 本次改造（推导场景、覆盖项、`inspect`、GUI 启动器/自定义模式/导出、两栏启动器与模拟 Dock、工作台舞台与原始桌面透射、内置合成样例、fixture 来源与清除、缺数据提示、可访问标签）**实现中**，尚未完成回归取证；以 `Tests/PluginPreview/` 的脚本结果为准，不把本文示例当作已验证。模拟 Dock 的悬停计时、浮层定位与槽位挂载没有截图证据；原始桌面透射下的玻璃外观依赖桌面背景，不能作为视觉基线。
- GUI 回归需要有屏幕录制授权的 runner；GitHub 托管 runner 默认没有，见 `.github/workflows/ci.yml` 的 `preview-gui`。

后台 iPod 坐标回归要求正视的 `wheel_ring` 扇区版夹具；未匹配该夹具格式的旧 revision 退出 77，不能将其截图成功或 2D 回归通过作为 3D 输入证据。提交候选范围与复验见 [rebase 记录](../../reviews/plugin-preview/plugin-preview-pr-rebase-2026-11-10.md)。

2026-11-11 的 PV-D16 已锁定新版 iPod 来源提交 `c2487864ae70e877ee539291884f4ae6e807fd11`，该不可变制品已通过完整后台交互回归；详见 [新版资产验收](../../reviews/plugin-preview/plugin-preview-ipod-lock-2026-11-11.md)。
