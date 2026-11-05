# 插件独立预览与开发工具方案

日期：2026-11-03。**状态更新（2026-11-03）**：本文是原始调研方案，其中的命令、协议与工期描述是**当时的建议**；实际实现与取证以 [任务书](plugin-preview-development-tasks.md)（PT-08 起的验收记录与 G0–G3 结论）、[契约 v1](plugin-preview-contract.md)、[使用指南](plugin-preview-guide.md) 与 [覆盖矩阵](plugin-preview-coverage.md) 为准；与它们不一致处以后者为准（文档是合同，实现是履约）。不覆盖 D20–D23、API-P 系列及既有插件外迁裁决。

执行拆分见 [插件独立预览开发任务书](plugin-preview-development-tasks.md)：T00–T21 明确任务依赖、写入范围、交付物及 G0–G3 阶段门禁；任务文档不代表开发或发布已经获批。

**1. 目标与建议**

建议提供 Switchly Plugin Preview：独立 macOS 原生预览程序、现有 CLI 的开发入口、可复现的场景文件。插件作者只取得插件仓库、版本化工具包和预编译预览程序，即可执行插件、查看真实原生控件、触发动作、导出截图和回归报告，无需安装或启动 Switchly 本体，也无需检出宿主源码。

这里的“无需本体”指不启动 Switchly 的菜单栏、Dock 监听、AX 扫描、真实窗口监控和媒体等系统服务；仍运行一个专用轻量预览程序。原生可视预览以 macOS 为目标；Windows/Linux 可保留静态与业务测试，不承诺等价原生截图。

推荐组合是“真实 JSC + 同源 SwiftUI/AppKit/Canvas 渲染 + 合成系统上下文”。浏览器适合未来展示已导出的报告，不作为第一版权威渲染器。独立预览验证插件在指定上下文中的表现，正式 Dock 定位、系统授权、跨屏、焦点及桌面玻璃仍需本体集成验证。

**2. 当前基础与缺口（静态核查结果）**

| 当前基础 | 可复用内容 | 缺口 |
| --- | --- | --- |
| `Plugins/cli/src/cli.js` | `create/validate/build/verify/api describe`；build 校验后复制，不转译 | 没有可视窗口、watch 或场景执行入口 |
| `Plugins/sdk` | 注册函数、UI 构造器、Context 与 Scene 类型 | 当前 private、0.0.0、未发布；ESM 仍需开发端形成 JSC 单入口 |
| `Tools/PluginVerifier.swift`、`make plugin-verifier` | 独立进程、真实 PluginRuntime/JSC、真实 UI/Scene 解码、安全 fake | 只执行首次 render，没有可视化、动作重放和完整 fixture 注入 |
| 外仓 `test-support/plugin-harness.mjs` | Node VM、可控 Timer、真实插件业务测试与树断言 | 不能证明 JSC、SwiftUI、Canvas、资产和原生输入正确 |
| `Sources/Views/PluginOverlayView.swift` | 原生声明式控件、动作回调、普通图片与 Scene 接入 | 依赖共享视觉类型，需要明确最小构建依赖闭包 |
| `Sources/Views/PluginSceneView.swift`、`PluginSceneDrawing.swift` | 原生 Canvas、动画、局部 hover/hit test | Date、TimelineView、settle timer 等尚无统一可注入时钟 |
| `Tests/UnitTests/PluginAssetBudgetTests.swift` | NSHostingView/窗口、ImageRenderer、真实像素验证范式 | 单个图片用例不能证明所有材质和视图都能离屏截图 |

需优先处理的契约差异：

- 外仓 `scripts/validate.mjs` 的设置类型集合包含 `string`，CLI 与 manifest schema 接受 `toggle/select/number`。应让外仓消费版本化公共校验规则，并保留更严格的仓库资产策略；用共享正反样本防止再次漂移，不在预览器内新增第三套规则。
- `PluginSlot` 可声明四种槽位，但当前 `DockPreviewView` 只接入 `center` 和 `bottomBar`。预览的宿主模式应反映实际支持矩阵；可单独检查另外两种槽位的节点，但必须标注“组件预览，当前 Dock 未接入”。
- `window.focus`、任意 AppleScript 仍未实现，不能通过 fake 让开发者误认为可用。supported、granted、available 必须分别展示和测试。

依据为 2026-11-03 的源文件阅读与 `rg` 检索，本次未重新运行既有单测，历史测试数量不作为本次通过证据。

**3. 竞品调研与取舍**

| 产品 | 官方开发路径与边界 | 可借鉴内容 |
| --- | --- | --- |
| Raycast | `ray develop` 导入真实 Raycast；保存自动重载，支持错误与日志；所查官方文档未提供替代宿主的独立 UI 模拟器 | 一条开发命令、自动重载、统一诊断、公开类型 |
| Stream Deck 桌面插件 | watch 后构建并 restart 插件，运行仍依赖 Stream Deck App；虚拟设备不等于独立宿主 | 明确“重启”语义、manifest 校验、运行与发布分层 |
| VS Code | Extension Development Host 与专用测试宿主；浏览器测试也是 VS Code Web 环境 | 开发宿主复用正式协议、隔离生命周期、专门集成测试 |
| Storybook | 独立组件场景、参数、play 交互、视觉基线；其网页渲染不能直接验证 SwiftUI/AppKit | fixture 驱动、场景目录、交互与视觉结果分开报告 |
| Stream Deck Kit iPad Simulator | 面向 iPad SDK 的硬件/布局模拟及 SwiftUI Preview，不是桌面插件宿主 | 预览器明确声明覆盖对象与限制 |

官方来源：

- [Raycast CLI](https://developers.raycast.com/information/developer-tools/cli)、[调试扩展](https://developers.raycast.com/basics/debug-an-extension)。
- [Stream Deck 入门](https://docs.elgato.com/streamdeck/sdk/introduction/getting-started/)、[修改与重启](https://docs.elgato.com/streamdeck/sdk/introduction/your-first-changes/)、[iPad Simulator](https://docs.elgato.com/ipad/simulator/)。
- [VS Code 首个扩展](https://code.visualstudio.com/api/get-started/your-first-extension)、[扩展测试](https://code.visualstudio.com/api/working-with-extensions/testing-extension)、[Web Extensions](https://code.visualstudio.com/api/extension-guides/web-extensions)。
- [Storybook args](https://storybook.js.org/docs/writing-stories/args)、[交互测试](https://storybook.js.org/docs/writing-tests/interaction-testing)、[测试概览](https://storybook.js.org/docs/writing-tests)。

上述是官方文档核查，未安装或实操这些竞品。Switchly 采用独立开发宿主是基于自身声明式 UI 与现有独立 JSC 校验器的工程判断，并非这些产品已经提供同等功能。

**4. 架构与仓库归属**

```text
插件作者 / Agent
       │ CLI：dev / run
       ▼
预览控制器 ── 包校验、fixture、watch、版本握手、进程监督、报告
       │                         │
       ▼                         ▼
原生 Preview App          独立 JSC Worker
共享 UI/Scene/资产/材质     共享 PluginRuntime/解码/预算
原生窗口与输入             合成 media/weather/fs/storage
       ▲                         │
       └──── 校验后的 UI 输出 ────┘
       └──── action/value ───────►
```

宿主仓库维护公开契约、SDK、CLI、预览程序与通用 fixture 协议；外仓维护具体插件、资产、专属场景与业务断言。插件源码和专属算法不回流宿主。首次用同一源文件进入多个 target 或小型共享模块，先证明依赖闭包；确有复用收益后再抽 Swift package，不先做大范围搬迁。

共享源包括 PluginUINode/PluginScene、Runtime/Validator、PluginOverlayView/SceneView/SceneDrawing/SceneAssets，以及 DesignTokens、MotionTokens、GlassEffect、NativeCrystalContainer 所需类型。必须追踪 CrystalMaterial、AppSettings 等间接依赖，只暴露必要展示参数，不把整个 SettingsService 或 App 生命周期引入预览。

宿主和预览共同消费渲染表面配置：槽位布局、尺寸单位、边距、材质、背景、外观、语言、reduceMotion、资产目录。首版保留独立预览外壳；逐步抽出宿主与预览都使用的槽位展示组件，避免复制 DockPreviewView 全文件。构建配置、资源 Bundle、可用性检查和降级分支纳入一致性检查。

JSC 放在独立工作进程：当前 Runtime 是软超时，预览控制器必须能终止卡死 worker、回收进程并保留诊断，使预览窗口和 CLI 可恢复。此处进程隔离只保证故障可回收，不代表完成恶意插件的系统安全沙箱，也不自动改变正式宿主执行架构。

**5. 第一版开发体验与命令契约（均待实现）**

第一版只新增两个主要入口，沿用现有 validate/verify，不先堆叠独立 inspect/action/snapshot 服务。

```sh
# 以下为拟议命令，当前不可直接运行。
switchly-plugin dev ./plugins/com.example.demo \
  --preview-tool /path/to/SwitchlyPluginPreview.app \
  --scenario ./preview/default.json

switchly-plugin run ./plugins/com.example.demo \
  --preview-tool /path/to/SwitchlyPluginPreview.app \
  --scenario ./preview/default.json \
  --out "$PREVIEW_OUTPUT_DIR" --json
```

`PREVIEW_OUTPUT_DIR` 由调用者指向系统临时目录中的任务目录；CI 可使用明确的产物目录。实际工具启动、默认路径发现和参数名称在 P0 冻结。

- `dev`：启动专用预览窗口，监听插件包；显示场景、主题/语言、诊断、重载按钮、截图导出。使用真实控件和 Scene hit test，交互调用真实 onAction 后重新 render。
- `run`：一次性装载场景、执行支持的步骤、导出报告和截图后退出。P0 只要求初始渲染与截图；P1 增加动作、时间推进和断言。
- 正常 stdout 在 `--json` 模式仅含一个版本化结果对象；日志走 stderr。报告区分 `passed/failed/unsupported/environment-error`，所有失败退出非零，CI 不把 unsupported 算作通过。
- 不隐式调用 make prepare-plugins、不刷新预装锁、不修改本体安装目录。普通插件开发无需更新宿主制品锁。
- 不隐式转译 TS；继续消费已有 main.js。可选 TS 模板作为后续单独能力，若增加打包依赖需说明并审批。

预览窗口至少提供插件区与诊断区、浅深色切换、en/zh-Hans 切换、玻璃开关、可调内容宽度、重载与重置。具体视觉布局后续设计确认，本提案不锁定新的视觉风格。

**6. 场景格式与 fake 系统能力**

新增 `preview-scenario.schema.json`，与插件发布 manifest 分离；preview 目录作为开发资料，不强制装入插件发行包。下例是拟议最小结构，不是现有 API：

```json
{
  "schemaVersion": 1,
  "id": "playing-zh-dark",
  "environment": {
    "locale": "zh-Hans",
    "appearance": "dark",
    "glass": false,
    "reduceMotion": true,
    "contentWidthPoints": 360
  },
  "target": { "bundleID": "com.example.player", "appName": "示例播放器" },
  "fixtures": { "media": "./fixtures/playing.json" },
  "storageSeed": {},
  "steps": []
}
```

fixture 必须通过公共能力类型/Schema 校验，不能用简化字段假装完整媒体快照。effective grants 是场景授权与 manifest 声明的交集；supported 从实际工具能力表派生，未实现 API 的 supported 不可由 fixture 改成 true。系统不可用与拒绝授权分开配置；动作记录包括 pluginID、actionID、value、调用能力、结果来源和序号。

| 能力 | 预览实现 | 关键场景 |
| --- | --- | --- |
| media | 合成曲目、封面、进度；play/pause 等更新 fixture 状态并记 trace | 播放、暂停、空曲目、无封面、拒绝授权、调用错误 |
| weather | 合成只读天气快照，不触发网络 | 有数据、null、过期、不可用 |
| fs | 合成目录/文件/锁状态；新增最小 reader 协议注入点，正式 PluginFileReader 复用原实现 | 空目录、未读/运行中、锁状态、权限拒绝、超限 |
| settings | manifest 默认值加合法场景覆盖，使用同一设置解码规则 | 默认、边界、无效值、hideWindowPreviews |
| storage | 每个场景独立临时存储、seed/reset/dump；默认不跨运行保留 | 首次运行、旧数据、超限、损坏 JSON |
| app/window | 合成目标、长标题、缺省活跃时间等 | 窄布局、长文案、无窗口 |

默认不读取真实用户目录、真实天气、媒体库或凭据，不继承本体设置和授权。工具允许读取的是用户显式指定的插件包与 fixture 路径；路径也执行普通文件、越界、符号链接和体积检查。worker 用环境白名单启动，不转发完整父进程环境。日志和报告默认不记录 fixture 内容和任意本机路径。

**7. 热重载、进程协议与生命周期**

1. 合并连续文件事件；检查并复制完整包到隔离快照目录，校验快照，避免正在写入的资源混用。
2. 新 generation 创建新 worker/VM、资源缓存和独立回调；加载成功后一次替换画面与动作路由。旧 worker 退出并回收。
3. JS 内存状态默认重置；storage 仅 dev 会话内按显式策略保留，run 默认每个场景重置。重载失败保留上一次成功画面，但明显标注 stale，不让失败截图计为通过。
4. 所有请求绑定 generation/requestID；每个 worker 只串行执行一个变更请求，旧返回、旧 invalidate、旧 timer 不得进入新会话。
5. 控制器 watchdog 同时覆盖启动、执行、关闭；超时 terminate，必要时 kill，随后 wait/reap；最多一次显式恢复，不无限重启。
6. 隐藏执行 suspend，显示 resume，关闭 unmount 并取消 watcher、timer、管道和子进程。重复 start/stop、安全关闭与卡死退出均列入回归。

内部建议使用带长度前缀的 UTF-8 JSON 帧；协议版本、消息类型、requestID、generation、payload 明确。限制单帧、总缓冲、日志速率与请求队列；数值从现有节点/包预算推导，在 P0 实测后冻结。部分帧累积读取，截断/非法 UTF-8/未知版本/超限均作为协议错误退出。协议 stdout 与日志 stderr 分离，禁止任意插件日志污染传输。控制器与 GUI 间采用继承管道或仅当前用户可访问的本地 IPC；首版不监听 HTTP 端口。

**8. Agent 交付物与可复现视觉验证**

`run --json` 返回统一报告与 artifact 清单，至少包含场景 ID、插件包哈希、工具/SDK/协议版本、generation、各检查状态、失败原因和文件相对路径。产物建议为：

```text
report.json          # 权威状态与环境指纹
preview.png          # 原生渲染产物
ui-tree.json         # 插件声明式节点，不冒充 SwiftUI 私有树或 AX 树
actions.json         # 带 pluginID/actionID/value 与 enabled 的动作
trace.ndjson         # 能力调用、状态与生命周期事件，不嵌入私密内容
```

P0 提供 report、PNG、声明式树和动作目录；P1 完成交互 trace、断言和基线比较。CLI 的 JSON 仅引用图片，不内嵌 base64。Agent 的基本闭环是运行场景、读取报告、实际打开截图、修改插件、重跑受影响场景，再复核差异；JSON 通过不能替代看图。

动作测试分两层：直接调用 actionID 验证业务路由；原生输入/辅助功能驱动验证控件可达、disabled、焦点和 Scene hit region。报告必须区分两者，不能把直调 onAction 写成“按钮已点击通过”。声明式树暂用 generation 内稳定路径；跨版本操作优先使用 pluginID + actionID，重名或歧义直接报错。

P1 为共享运行时与共享渲染器增加可注入时间/随机源，正式模式默认沿用系统实现：覆盖 JS Date/Math.random/受控 Timer、Scene epoch/time、TimelineView 的绘制时刻、hover 过渡、settle timer 和 marquee。JS clock 在 VM 初始化时注入且标记为测试模式；不修改系统时间、全局用户偏好或插件源码。时钟只覆盖一半时不得声称确定性回归。

截图分两条路径：

- 稳定基线：固定合成背景、plain 材质、字体/颜色空间/scale、输入与时刻，用验证过的原生截图路径。ImageRenderer 对复杂材质/NSViewRepresentable 不保证完整，先做能力 spike，缺失层必须报不支持或改用真实窗口路径，不能静默输出空白图。
- 原生表面：真实窗口与 WindowServer 验证玻璃、透明背景、控件 hover/focus。截图捕获方案可能有系统授权约束，显式诊断；此路径不纳入跨系统严格像素相等判断。

基线键至少包含 preview 版本与源码 revision、macOS build、架构、语言、主题、scale、颜色空间、字体信息、场景版本和包哈希。环境不一致先报告 baseline-incompatible，不自动覆盖。像素差异只用于辅助回归，几何、可操作性和人工看图分别记录；基线接受必须显式操作。

**9. 分发、兼容与 CI**

先提供本地 npm pack 的 SDK/CLI tarball、固定版本的 Preview.app 与其 worker、版本清单和 checksum，实现不读宿主源码的干净环境演练。后续经明确发布授权再发布 npm 与签名/公证的 macOS 工具；首版不引入自动更新器、远程下载或在线 Registry 依赖。

预编译工具优先 universal2，未完成双架构实测时分别标识支持范围。构建仍要求 Xcode 26+；作者使用预编译工具不需要 Xcode。最低运行系统以实际所选 API 与回归为准，目标与宿主 macOS 12 兼容；若截图路径仅支持较新系统，应明确按命令/能力降级，不悄悄抬高全部工具门槛。

握手区分 preview 工具版本、内部 IPC 版本、scenario schema、plugin apiVersion 和 SDK 契约版本/哈希；不兼容时在执行插件前拒绝，并给出应安装的版本范围。预览器不根据版本号猜测支持 API；运行时能力列表随二进制一起发布。

CI 分层：Linux/通用 Node job 跑静态校验与业务测试；macOS JSC job 跑真实执行/解码/动作契约；具有可用图形会话的 macOS runner 跑原生视觉与交互。不得承诺任意后台 runner 均能启动 WindowServer；无 GUI 时 doctor 与 run 明确报告环境不支持，不假通过。正式本体保留 Dock/授权/AX/多屏/玻璃集成门禁。

**10. 可执行实施拆分与退出标准**

估算为一名熟悉本项目的工程师有效工作日；需要 P0 spike 校正，签名证书/CI 图形环境的外部等待不计入。可并行处理 CLI 和 fixture，公共协议、依赖拆分及最终验收由主控负责。

| 阶段 | 工作项与拟修改范围 | 退出标准 | 估算 |
| --- | --- | --- | --- |
| P0a 可行性与契约 | `Plugins/api/` 新增开发场景 schema；梳理共享依赖；`project.yml` 配预览 target；核查截图与窗口 API | 真实控件、Scene、图片各一例从独立进程显示；明确 macOS/GUI/截图能力矩阵；修正外仓校验漂移 | 2–3 日 |
| P0b 可用 MVP | Preview App/worker；CLI dev/run；初始 fake、主题语言、基本动作、watch、错误展示、PNG/tree/report | 三个现有插件均可在本体未运行时预览；死循环只终止 worker；失败不伪装新成功画面 | 4–6 日 |
| P1 可回归工具 | 公共时间源/随机源、fixture 状态机、场景步骤、动作/原生输入区分、trace、基线与兼容诊断 | 相同环境同场景可复现；权限/生命周期/错误用例通过；人工读取截图验证 | 4–6 日 |
| P2 独立交付 | 版本化 tarball、签名分发流程、干净环境演练、macOS CI、开发文档与Agent示例 | 只有插件仓库和发行工具也能完成 build→run→看图→修复→重跑；本体集成回归无新增失败 | 2–4 日 |

合计约 12–19 个有效工作日；第一版可视 MVP 约 6–9 日。P0 不建设浏览器渲染器、市场、账户、通用插件 IDE、MCP server、完整 TS 工具链或正式宿主进程隔离改造。

拟议验收清单：

1. 本体未运行、无 AX/屏幕录制授权，使用合成数据能启动原生预览；截图能力若需额外权限则明确分项，不阻止其他检查。
2. 音乐：空/播放/暂停/长标题/无封面/权限拒绝；天气：有/无快照、选择/揭示/结束；鲸娘：合成空会话/未读/忙碌/数量上限；具体业务场景只放外仓。
3. 浅深色、en/zh-Hans、玻璃开关、reduceMotion、目标宽度和支持槽位均检查；覆盖组合采用基础场景加针对性边界，避免无意义全笛卡尔积。
4. 非法包、JS 异常、无效输出、动态越界资产、预算溢出、卡死、过期返回、重载/隐藏/关闭过程均有明确结果。
5. 预览与宿主用同一通用 fixture 验证节点、布局边界、资产与动作路由；不复制插件算法进宿主测试。
6. Swift 改动执行 `make build`、`make test-unit`；SDK/CLI 执行对应 `npm test`；插件外仓执行 `npm test`、`npm run build`；新增预览测试命令必须先落入 Makefile/工具后才作为门禁引用。
7. 发布包在无宿主源码的环境验证，支持架构分别实测；性能先记录冷启动、重载 p50/p95、静止 CPU/内存、关闭后的残留进程，不能把未测数字写成保证。

**11. 提案台账与实施顺序**

以下编号仅用于本提案，均为“建议”，不构成用户批准的产品裁决。

| 编号 | 日期 / 建议 | 依据 | 影响面 |
| --- | --- | --- | --- |
| PP-01 | 2026-11-03 / 原生独立开发宿主为权威预览 | 真实渲染器为 SwiftUI/AppKit/Canvas，已有独立 JSC verifier | 工具架构与平台范围 |
| PP-02 | 2026-11-03 / 同源复用，先最小 target 后按需抽包 | 当前 Renderer 有视觉与设置类型依赖，整体搬迁成本未实测 | 工程组织与宿主回归 |
| PP-03 | 2026-11-03 / fixture 默认纯合成，worker 可终止 | Runtime 软超时；插件外仓已有 fake 测试 | 数据边界、生命周期 |
| PP-04 | 2026-11-03 / dev/run 两入口与统一产物 | 多 Agent 复审建议减少重复接口与结果格式 | CLI、Agent 消费 |
| PP-05 | 2026-11-03 / 稳定截图与真实玻璃分别验收 | ImageRenderer 对合成层/原生窗口存在边界 | 截图与CI可靠性 |
| PP-06 | 2026-11-03 / 先收敛校验漂移，明确槽位支持 | `rg`/源文件发现外仓 string 设置与宿主 schema 不一致；Dock 仅接两槽位 | 外仓校验、能力说明 |

后续应先实施 P0a 并提交可运行的独立窗口证据，再依据测得依赖和截图结果冻结 P0b 工作量；获批裁决应另登记正式台账并反链本文。本次只交付调研与方案，没有实现预览程序，没有执行或授权工具发布。

**12. 实施记录：T00 初步契约清点（2026-11-03）**

本记录是实施时的实测补充；原文的调研日期和提案状态保留历史语境。用户已授权按本计划开发，公开发布仍需另行授权。G0 尚需 T01 原生窗口及截图证据和 T02 接口冻结，不能因以下静态清点而放行。

| 源文件 | 已确认的职责与依赖 | 后续归属 |
| --- | --- | --- |
| `Sources/Models/Plugins/PluginManifest.swift`、`PluginUINode.swift`、`PluginScene.swift` | manifest、四槽位、声明式节点和 Scene 的宿主模型与解码规则 | 复用同一源码；场景协议不得取代宿主解码 |
| `Sources/Services/Plugins/PluginRuntime.swift` | JSC、受控 timer、动作和能力注入；授权与 manifest 取交集；默认减少动态效果读取系统设置 | worker 复用；预览必须显式注入合成依赖 |
| `Sources/Services/Plugins/PluginFileReader.swift` | 文件系统配额、路径与敏感目录检查；Runtime 当前依赖具体类型 | 为合成文件系统增加最小协议注入点，正式实现保持原规则 |
| `Tools/PluginVerifier.swift`、`Makefile` 的 `plugin-verifier` | 独立编译真实 Runtime/解码器，使用假媒体与临时 storage，禁用 fs 权限；只验证首次 render | worker 可参考依赖与隔离方式，不复制执行器 |
| `Sources/Views/PluginOverlayView.swift`、`PluginSceneView.swift`、`PluginSceneDrawing.swift` | 原生控件、Scene、资产和交互渲染；依赖设计令牌、材质及当前时间/减少动态效果 | 同源共享；具体闭包和截图能力待 T01 证实 |
| `Sources/Views/DockPreviewView.swift` | `DockPluginSlotView` 实际接入 `center`、`bottomBar`；数据与设置依赖宿主模型 | 共享表面应避免装配宿主生命周期或整个设置服务 |
| `Plugins/cli/src/validate.js`、`Plugins/api/manifest.schema.json`、外仓 `scripts/validate.mjs` | CLI 设置类型为 `toggle/select/number`，外仓当前为 `number/select/string`；另有外仓资产及双语规则 | T03 收敛公共校验，保留仓库专属严格规则 |

当前 `PluginRuntime` 将 `window.focus` 与 AppleScript 标为不支持；能力状态区分 supported、granted 和 available。正式宿主的真实媒体、天气、用户目录、Dock 和 AX 服务不能由预览进程默认装配。`PluginSceneView` 当前使用 `Date`、`MotionTokens.reduceMotion`，确定性时钟尚未覆盖。

本机证据：`sw_vers` 为 macOS 27.0.1（26A434），`xcodebuild -version` 为 Xcode 27.2（27B52），`uname -m` 为 arm64。2026-11-03 运行 CLI 的 `npm test`：12 通过、0 失败；外仓 `npm test`：21 通过、0 失败。这些结果仅是现有基线，不证明独立预览可用。macOS 12、Intel、无图形会话、原生截图和玻璃能力尚未验证。

同日 `make plugin-verifier` 构建成功；分别对外仓 music-controls、weather-gacha、whale 插件目录运行 `.build/tools/switchly-plugin-verify`，三次均以退出码 0 完成真实 JSC 首次 render 和宿主解码，各返回 1 个槽位。该 verifier 不授权 `fs.read`，不会验证原生渲染或交互。包预算由 `PluginPackageValidator` 定义为 32 MiB、1024 条目、manifest 256 KiB、单入口 2 MiB；声明式输出预算由 `PluginRenderOutput` 定义，预览协议预算须依据实际数据和这些现有约束确定。

渲染闭包清点发现 `CrystalMaterial` 位于 `AppSettings.swift`，直接引用会连带多种设置和统计模型；不能靠复制材质类型建立平行实现。`SceneEvaluator.swift`、`PluginGrant.swift`、`PluginRegistry.swift`、`PluginPackageValidator.swift` 也在当前可类型检查的依赖闭包内。`SceneAssets` 在相同路径重载时需要重建，避免沿用旧资源缓存。`project.yml` 的项目级签名配置会被新 target 继承，预览 target 需显式核对并隔离主程序的 entitlement，不能复用带权限说明的主程序 Info.plist。上述均为工程风险，方案尚未因此冻结实现。
