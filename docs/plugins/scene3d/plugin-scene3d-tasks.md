# 插件 `scene3d` 子任务与验收门禁

> 日期：2026-11-06。依据：[实施方案](plugin-scene3d-implementation-plan.md)与[选型结论 C-D01](plugin-3d-rendering-options-2026-11-06.md)。状态：**T00 合同冻结完成，G0 未通过**；此前 C-V01～C-V07 是独立技术探针，不计入下面的正式宿主任务完成度。公开契约与 SDK 类型已写入；动态表面及输入已有局部实现，但宿主 `scene3d` 解码、共享渲染和正式槽位接入仍未完成（T04～T07）。

## 1. 交付物与协作边界

最终交付是通用 `scene3d` 插件能力，以及 `../switchly-plugins/plugins/com.switchly.music-controls` 在真实 Switchly Dock 槽位内可用的写实 iPod。宿主只拥有模型校验、加载、2D 表面、输入、可访问性和资源生命周期；音乐的资产、文案和交互映射由外仓插件拥有。第二种气压计模型是通用能力的回归样本，不把其业务写入宿主。

| 工作包 | 主写入范围 | 交接边界 |
| --- | --- | --- |
| 契约与集成 | `docs/plugins/`、`Plugins/api/`、`Plugins/sdk/`、预览合同 | 冻结字段、兼容与预算；统一核对各任务实现，不让并行任务各自定义 API。 |
| 资产安全与构建 | `PluginPackageValidator` 所在模块、公共资产校验、`project.yml`/构建脚本 | 唯一入口做 GLB 预检和解码预算；工程接线串行处理。 |
| 通用原生渲染 | `Sources/Models/Plugins/`、`Sources/Services/Plugins/`、`Sources/Views/` 新 3D 组件 | 不包含插件 ID、歌曲 UI 或气压计业务；预览共用同一文件。 |
| 插件与场景 | 相邻 `switchly-plugins` 的音乐包、资产、测试、预览场景 | 保留旧 2D 模式；真实媒体动作由现有 `onAction` 处理。 |
| 验收与性能 | `Tests/`、预览场景、真实面板截图/视频与测量记录 | 主控综合判定 G0–G4；子任务通过不自动等于产品通过。 |

同一文件只有一个任务在同一时间写：`project.yml`、`PluginUINode.swift`、`PluginOverlayView.swift`、`PluginRuntime.swift`、`PluginPackageValidator.swift`、预览契约和外仓 `main.js` 由集成者串行合并。新文件可按工作包并行。交接须附实际修改文件、接口版本、命令与关键输出、已查看的画面及未验证项。临时探针与日志放系统临时目录；正式资产、夹具、截图按仓库约定保留。

## 2. 总表与关键路径

| ID | 任务 | 前置 | 输出 | 状态 |
| --- | --- | --- | --- | --- |
| T00 | 正式合同与预算冻结 | C-D01 | 设计台账、字段、兼容、正反样本、G0 | 合同冻结完成（证据：D26、API 参考 §9、`capabilities.json`/`index.d.ts`、`Scene3DContractFixtureTests` 8/8、全量单测 713 条（8 跳过）0 失败（以 v2 包构建为准）、合同哈希一致）；**G0 未通过**（真实 Dock 尺寸、2D 性能基线、v1.3.0 旧宿主实机回退与宿主渲染仍未验，见 T00 记录） |
| T01 | GLB 预检与资源预算 | T00 | 宿主安全入口、公共夹具 | 进行中（宿主预检测试 21/21，CLI 测试 67/67；CLI 图片格式覆盖较窄，无 UV 屏幕检查及运行时接线尚未完成） |
| T02 | GLTFKit2 工程集成 | T00 | 固定版本、嵌入签名、离线构建证明 | 已完成（Debug 侧；证据：`make generate`/`make build`/`make plugin-preview-build` 成功，GLTFKit2 0.5.15 嵌入 `Contents/Frameworks` 并以 Hardened Runtime 签名，`codesign --verify --deep --strict` 通过，`make plugin-preview-contract-check` 一致，`make test-unit` 565 条 0 失败，GLTFKit2 集成测试通过；Release/`make dist` 真机由用户验收，Intel、macOS 12 真机按用户决定移除，未验） |
| T03 | 可交付 iPod 模型资产 | T00 | glb、命名网格、UV、PBR/环境素材 | 进行中 |
| T04 | 受限 2D 动态表面 | T00、T01 | 共用表面解码/绘制/纹理更新 | 进行中（合同白名单、badge 绘制及缓存已有单测：`PluginSurfaceRendererTests` 22/22；子代理查看浅/深/空状态及 badge PNG；解码器拒绝非法输出接线、真实 SceneKit 材质与插件目录端到端加载仍待核验） |
| T05 | 通用相机、旋转与拾取 | T00、T03 | 输入/命中/动作路由组件 | 进行中（逻辑单测 37 条；预览 target 已编译共享输入组件并通过共享源码守卫；真实 SCNView 鼠标、触控板、键盘及 VoiceOver 仍待验证） |
| T06 | 共享 `scene3d` 渲染组件 | T01、T02、T04、T05 | 宿主/预览共用的生命周期闭环 | 进行中（独立组件已有加载、场景装配与生命周期单测，预览 target 已编译共享源码；真实渲染和应用生命周期验证尚未完成） |
| T07 | 正式 Dock 槽位接入 | T06 | `center` 槽位与窄槽后备 | 待实施 |
| T08 | 独立预览与 CLI 契约接入 | T06 | 共用渲染、场景与报告 | 进行中（共享源码编译和链接通过；预览入口、场景与真实渲染尚未完成） |
| T09 | 音乐插件外仓迁移 | T03、T07、T08 | 新可选 iPod 模式、保留旧布局 | 进行中（外仓 v1/v2 双发行线与 2D 后备已实现，`npm test` 44/44、`npm run validate` 与 `npm run build` 通过；默认线与宿主锁逐文件一致；原型仅提供播放命中，真实宿主验证未完成） |
| T10 | 安全、兼容和系统回归 | T07、T08、T09 | 失败分支、macOS 12/签名/输入证据 | 待实施 |
| T11 | 写实材质与运动画面收敛 | T07、T09 | 实际面板正侧背及旋转视频 | 待实施 |
| T12 | 第二造型通用性回归 | T07、T08 | 气压计独立插件样本，不改宿主造型代码 | 待实施 |
| T13 | 生命周期及多卡片性能 | T07、T08、T09 | 冷/热首帧、帧时、CPU/GPU/RSS 与回落 | 待实施 |
| T14 | iPod 端到端产品验收 | T10、T11、T12、T13 | G3 证据与明确 Go/No-Go | 待实施 |
| T15 | 文档、工具与发布候选收口 | T14 | 公开 API、README、CHANGELOG、G4 | 待实施 |

关键路径：**T00 → T01/T02/T03 → T04/T05 → T06 → T07/T08 → T09 → T10～T13 → T14 → T15**。T01、T02、T03 可并行准备；T07 与 T08 在 T06 后并行；T10～T13 在共同纵向切片形成后按独立场景推进。任何单项失败要修正该项，不用调整合同或关掉门禁掩盖。

## 3. 任务定义

### T00 — 正式合同与预算冻结（G0）

- **工作**：在 `dock-preview-plugins-design.md` 追加正式裁决，注明 D03/D12 与 C-D01 的关系；把 `scene3d`、`ctx.uiFeatures.scene3d`、旧宿主回退、窄槽 `fallback`、表面节点子集、相机单位、glTF 节点命名、命中 ID、错误语义和预算写入 API 参考、机器可读清单与 SDK 类型。确定是否沿用 v2 协商增量；用旧宿主样本验证默认音乐卡片仍能加载。冻结 220×380 pt 候选可读边界及资源硬值。
- **验证**：有效 iPod、气压计和旧布局样本通过；未知节点、重复 action ID、缺失命名节点、超预算和旧宿主特性缺失有确定结果。`make plugin-preview-contract-check` 在更改预览合同时实际运行；哈希随合同更新。
- **完成定义**：合同字段、责任层和正反样本可让 T01～T09 独立开发，无相互矛盾。G0 未过不得接入正式槽位。

### T00 排查记录（2026-11-06，合同已冻结，G0 未通过）

- **命名事实**：三份技术探针 glb 的语义标识在 glTF `node.name`；原型 iPod 的 11 个 `mesh.name` 均为空。拟定的表面/命中字段已改为 `node`。原型只有 `mesh_wheel_play` 一个转盘动作节点，T03 还须交付前后曲和喜欢的独立可见节点。
- **兼容事实**：已发布 v1.3.0 宿主只接受 API v1；当前音乐插件也是 v1。把同一插件包直接升级为 v2 后，旧宿主会在加载时拒绝整包。当前支持 v2 但不支持 `scene3d` 的宿主会拒绝未知节点，故新插件必须依据 `ctx.uiFeatures.scene3d` 返回旧 2D 树。发布路径已由用户裁决（设计台账 D25）：外仓保留 v1 的 2D 包并另发 v2 `scene3d` 包，新宿主只加载 v2。D26 已把该规则冻结为「同一插件 ID 的两条发行线」，任一宿主锁文件只能锁一条线；外仓目录/分支/revision 与锁文件由 T09 落地。
- **预算事实**：当前 2 MiB `maxEntryBytes` 只约束 JS 入口，不能当成 glb 单文件上限。现有三个技术样本远小于冻结的 8 MiB / 128 网格 / 150000 三角形 / 256 节点；它们没有正式高分辨率贴图，不能据此判定最终资产或解码预算通过。
- **合同冻结结果（D26）**：字段、单位、预算、降级与错误语义已写入 `plugin-api-reference.md` §9、`Plugins/api/capabilities.json`（`ctx.uiFeatures`、`ui.scene3d`）、`Plugins/api/manifest.schema.json`（仅说明 `apiVersion: 2` 不等于可渲染 3D）与 `Plugins/sdk/index.d.ts`（`PluginScene3DNode` 等）。`scene3d` 只能作为 slot 根、每 slot 至多一个；窄槽阈值 220×380 pt 标为冻结候选，真实 Dock 尺寸仍未测。
- **夹具与测试证据**：新增 `Tests/Fixtures/Scene3D/` 正样本（`valid/ipod.json`、`valid/barometer.json`）、旧布局（`legacy/layout.json`）、反例（`invalid/unknown-node.json`、`invalid/duplicate-action-id.json`、`invalid/missing-named-node.json`、`invalid/over-budget-declaration.json`、`invalid/over-budget.glb`）与旧宿主缺失特性样本（`compat/legacy-host-missing-ui-features/`）。`Tests/UnitTests/Scene3DContractFixtureTests.swift` 8 条通过；`GLBPreflightTests` 13/13、`GLTFKit2IntegrationTests` 1/1 仍通过；`make test-unit` 共 713 条、8 条跳过、0 失败（v2 包构建，后续宿主接线后复跑）。
- **命令证据**：`./Tools/PluginPreview/contract-hash.sh` → `sha256:e79b66fc5924adac456bafecc135f7ccae6aac9291e497de1bb9aa84c839990b`，已同步到 `PluginPreviewWorkerProtocol.swift`；`make plugin-preview-contract-check` 输出「契约哈希一致 / 渲染器 revision 一致 / 共享源码守卫通过」。
- **未验项**：真实 Dock 尺寸（当前环境只有模拟/无头测量条件，未在真实 Dock 面板实测 220×380 pt 可读边界）；2D 性能基线（未在真实 Dock 面板采集首帧与帧时）；v1.3.0 旧宿主实机回退（旧二进制不可用，只验证了“当前宿主不注入 uiFeatures 时插件返回 2D”）；宿主 `scene3d` 解码/渲染（T04～T07 未实现）；SDK 类型未用 `tsc` 验证（本机无 `tsc`，`npm test` 的 types 解析项跳过）；`make test-unit` 运行于当前开发机，Intel/macOS 12 未验。
- **G0 补充调查（2026-11-07）**：按当前代码推算，最小 300 pt 面板的中心槽扣除左右内边距后约 284 pt 宽，现有 2D 卡默认高度为 132 pt；这不是实际槽位测量。未来 3D 节点如何申请 380 pt 高度及受屏幕可见区域约束后的回退仍需验证。一次 CoreGraphics 窗口列表读取到 Switchly 窗口 bounds 为 980×286 pt，但未能确认窗口类别或测量槽位；`screencapture` 返回 `could not create image from window`，没有截图证据。现有预览性能脚本不测真实 Dock。本地存在 v1.3.0 tag，但尚未找到可确认来自该版本的二进制，旧宿主实机验证仍未完成。
- **G0 结论**：合同冻结与正反样本已完成，但上述未验项与宿主渲染缺失使 **G0 仍未通过**；不得据此接入正式 Dock 槽位。

### T01 — GLB 预检与解码预算

- **工作**：在现有 `PluginPackageValidator` 路径增加 3D 资产预检；先解析 GLB chunk/JSON，再交给 GLTFKit2。拒绝外部 URI、越界 bufferView、未批准扩展、畸形 JSON、压缩炸弹式纹理和超预算模型。确保解析或加载失败仅使当前节点降级，保留插件其他 UI。CLI 使用同一组恶意/合法样本，宿主为最终防线。
- **验证**：C-V07 的 `../../sentinel.png` 和绝对/网络 URI 在**调用加载器前**被拒绝；大纹理、重复/空节点名、无 UV 屏幕和破损 GLB 有稳定错误；合法两模型仍可加载。检查符号链接与包总限额继续生效。
- **完成定义**：没有模型内部路径绕过或无界解码；错误不阻塞主线程。
- **进度证据（2026-11-07）**：宿主预检已收紧 chunk 顺序和边界、JSON 类型与深度、buffer 声明、扩展白名单及预算溢出检查。子代理报告 `GLBPreflightTests` 21 项通过，`make build` 成功，`make test-unit` 执行 639 项、跳过 8 项、失败 0 项。CLI 子代理报告公共夹具及畸形输入测试 17/17、CLI 全量测试 67/67；CLI 仅识别 PNG/JPEG，可能比使用 ImageIO 的宿主更严格，尚需核对合同兼容性。子代理已使用包含 `src/glb.js` 的 CLI 离线包完成外仓安装与校验。预检并非完整 glTF 字节布局校验器；无 UV 屏幕和运行时接线仍待验证。

### T02 — GLTFKit2 工程集成

- **工作**：固定可审查的 GLTFKit2 0.5.15 包校验和及 MIT 许可证；决定 XCFramework 嵌入方式，修改 `project.yml` 后生成工程，检查框架嵌入、签名、Hardened Runtime、Release 打包和预览 target 共用。确保日常 build/test 不在隐式流程刷新插件 lock 或下载运行时资源。
- **验证**：`make generate`、`make build`、`make plugin-preview-build`；在干净环境演练依赖获取/离线构建；检查实际运行 App bundle 中动态库路径与签名。macOS 12、Apple Silicon 与 Intel 分别记录可构建和可运行证据。
- **完成定义**：不依赖临时 `DYLD_FRAMEWORK_PATH`，真实 App 与 Preview 均能加载相同 glb。
- **待办（2026-11-07）**：只读调查发现 Debug App 已嵌入 GLTFKit2 框架；源码包含 GLTFKit2、cgltf 和 JSMN 的 MIT 许可，以及声明采用 Apache-2.0 的 libktx。二进制还可能静态包含其他组件，libktx 版本证据存在冲突；须核实实际组件、版本、完整许可文本和 NOTICE，并将适用声明随产物提供。Release、发行包与旧系统验证仍未完成。

### T03 — iPod 资产制作与材质验收

- **工作**：在外仓以原型几何为起点制作干净的封闭薄机身；拆分白色前板、金属侧边/背板、LCD 唯一显示面和转盘四方向可见命中网格。移除透明占位面；提供 UV、法线、模型单位、环境预设请求、glb 生成和校验步骤。静态纹理/贴花属于插件资产，歌曲数据不烘进模型。
- **验证**：Blender/Three.js 导出后经公共预检；正侧背与原型逐张对照；屏幕/转盘网格可命中且背面不命中正面；资产满足 G0 预算。美术视觉差距记录到 T11，不用伪造固定高光。
- **完成定义**：资产可由插件仓库独立打包，宿主无需设备专用代码。

### T03 资产修正（2026-11-06）与转盘拆分（2026-11-07）

2026-11-06 起外仓 `ipod.glb` 以 Three.js 原型导出的 `ipod-source-geometry.glb` 为起点（487760 字节），当时只有 `mesh_wheel_play` 一个命中节点。

2026-11-07：按转盘圆心角把原 `mesh_wheel_play` 的 96 个三角形拆为四个独立扇区网格（各 24 三角形、顶点按扇区压缩、包围盒各自重算）：`mesh_wheel_love`（上）、`mesh_wheel_previous`（左）、`mesh_wheel_next`（右）、`mesh_wheel_play`（下，对应 toggle）。其余节点与材质不变，节点名唯一；插件 `hits` 声明四项（`showLove=false` 时省略喜欢），外仓测试校验每个命中节点存在且使用独立网格。宿主 lock 已通过 `make update-plugin-lock` 显式更新（来源提交待外仓提交后重新锁定）。T03 的真实运行截图验收与写实门禁仍未通过。

### T04 — 动态表面

- **工作**：从受限节点树生成屏幕纹理，复用现有文字、封面、进度语义和宿主封面缓存；冻结 UTF-8 长标题、双语、无封面、暂停/空曲目排版。检查 `ImageRenderer` 已知进度差异，必要时提取宿主共用 2D 绘制原语。仅内容变更时更新，纹理按实例拥有；记录图像方向、色彩空间、像素密度与清理。
- **验证**：切歌/暂停/进度与封面变化后屏幕更新；重复 `render()` 而数据不变不重复上传；旋转中不出现倒置或 Z-fighting。预览与宿主同一内容输出相同像素（允许系统外观差异按契约记录）。
- **完成定义**：iPod 屏幕不依赖浏览器 Canvas、逐帧 JS 或第二套不受控 UI 树。

### T05 — 通用输入与可访问性

- **工作**：本地拖动控制 yaw/pitch；区分点击/拖动，网格拾取按前方可见面过滤；动作 ID 经现有 `onAction`。建立独立可访问文本、播放动作、喜欢状态和视角重置；减少动态效果禁惯性，保留直接操作。输入监听与场景同生命周期。
- **验证**：正面四方向、侧面和背面；真实鼠标、触控板、键盘、VoiceOver；隐藏/卸载后无回调。`nativeClick` 应命中实际语义动作，不能只调用业务动作冒充输入通过。
- **完成定义**：交互不靠屏幕坐标硬编码或 iPod 专属分支。

### T06 — 共享渲染组件与生命周期（G1）

- **工作**：将 T01～T05 装配为 `PluginScene3DView` 类通用组件，宿主与预览直接编译同一源码。异步加载以插件 ID、资产哈希、代次防旧结果覆盖；主线程修改 UI/SceneKit；隐藏停止主动帧循环，卸载释放 GPU 资源。缓存只共享不可变资产，动态材质按实例隔离。
- **验证**：加载成功、失败回退、反复 start/stop、快速切曲/切目标、两个不同实例与同插件两个实例不串屏；渲染源码共享检查通过。`make build`、`make test-unit`。
- **进度证据（2026-11-07）**：子代理报告已实现独立描述、预检加载、实例装配、控制器及视图；`make build` 成功，`make test-unit` 执行 696 项、跳过 8 项、失败 0 项。真实 probe GLB 的 CPU 解码测试通过；真实 GPU 渲染、截图、应用生命周期与无障碍交互尚未验证。子代理随后报告预览 target 已编译新增共享组件并通过共享源码守卫；正式 Dock 未接入。
- **完成定义**：G1 独立原生可视纵向切片通过，且无资源所有权悬空。

### T07 — 正式 Dock 槽位接入

- **工作**：在 `PluginUINode`、`PluginOverlayView`、`PluginSlotSurface` 与真实 Dock 面板接入新节点，不增加音乐 ID 分支。按尺寸使用 3D 或后备，按现有 glass/主题设置合成；多插件叠放不互相覆盖。`usesArtwork`、动作去重和布局测量纳入通用解码规则。
- **验证**：真实 Dock 面板正侧背截图、默认 120 pt 与可读大尺寸、三插件叠放；浅/深色与玻璃开关；拒绝未知节点不致空白。运行 `make build`、`make test-unit` 后实际看图。
- **完成定义**：真实槽位显示与操作可用，不能以独立 NSPanel 探针代替。

### T08 — 独立预览与 CLI 接入（G2）

- **工作**：预览 App/worker 编译 T06 共用代码；外仓场景增加 3D 音乐与气压计夹具，`report.json` 记录资产哈希、渲染器版本和降级原因；需要 3D 姿态步骤时扩展预览 Schema 与命令，保持旧场景有效。共享源码、合同哈希与 renderer revision 同步。
- **验证**：`make plugin-preview-contract-check`、`make plugin-preview-build`、预览场景成功/无权限/破损资产/窄槽回退；真实截图、UI 树和动作 trace 一致。后台预览输入限制按既有契约报告，不声称它能执行原生点击。
- **进度证据（2026-11-07）**：子代理报告预览 App 已编译并链接 T04～T06 共享源码与 GLTFKit2；`make plugin-preview-contract-check`、`make plugin-preview-build` 通过，共享源码守卫覆盖 33 个核心类型。预览入口尚未实例化 3D 组件，场景、报告、真实截图及交互均未验收。
- **完成定义**：插件作者不启动 Switchly 本体即可预览同一 3D 渲染实现。

### T09 — 音乐插件迁移

- **工作**：外仓 `main.js` 增加默认关闭的 `ipod3d` 设置；支持时返回 `scene3d`，旧宿主/窄槽退回 2D；保留普通卡片及 `wheelLayout`。真实歌曲、歌手、封面、进度、喜欢状态、播放暂停来自现有媒体 API；转盘四方向动作仍用原 `onAction`。
- **验证**：外仓 `npm test`、`npm run build`；插件 CLI 校验与预览场景；新旧宿主、空歌、无封面、长标题、英文/中文。`make update-plugin-lock` 只在明确接受外仓新制品的集成阶段运行并审查哈希，普通构建不得自动更新。
- **进度证据（2026-11-07）**：子代理报告外仓默认 `dist/Plugins` 提供音乐 v1 兼容线，`dist-v2/Plugins` 提供 v2 线；默认线与当前宿主锁逐文件一致，外仓 `npm test` 44/44、`npm run validate` 和 `npm run build` 通过。子代理使用新 CLI 离线包完成外仓校验，并报告宿主 `make prepare-plugins` 通过（3 个插件）；新旧宿主运行尚未验证。原始模型只有一个播放命中节点，四个 3D 媒体动作尚未完成。
- **完成定义**：新 3D 模式可选，旧媒体控制无功能回退。

### T10–T13 — 风险收敛

- **T10 安全/兼容**：越界 URI、畸形纹理、权限缺失、加载超时、签名/动态框架与 macOS 12 真机；失败按类型记录，绝不读取包外私密文件。`./verify.sh` 与适用测试通过。
- **T11 写实视觉**：环境反射随旋转变化、白色正面和金属侧背、薄封闭机身、无屏幕条纹；原型参照与真实面板正侧背/连续视频对照。若 SceneKit 无法达标，记录具体差距和资源代价，回到 C-D01 的退出条件。
- **T12 泛化**：气压计以独立插件交付，换资产和声明即可复用；不能修改宿主增加气压计网格名或操作分支。再测它的动态表面/动作，避免仅凭静态截图宣布通用。
- **T13 性能**：以当前 2D 音乐卡片为基线，在目标机器测冷/热首帧、拖动 p95 帧时、空闲 60 秒 CPU/GPU、四卡片驻留与反复开关 50 次后的回落；按 T00 冻结阈值判断。独立短命进程的 46–54 MB RSS 只作估算，不作正式门禁。

### T14 — iPod 端到端产品验收（G3）

主控对[实施方案 §4](plugin-scene3d-implementation-plan.md)的五组要求逐项核对，在真实 Switchly Dock 槽位观看正侧背截图和连续旋转视频；实际操作四个媒体动作、回退布局、键盘/VoiceOver 与减少动态效果。记录目标系统、架构、App bundle 路径、签名、插件来源 revision、外仓/宿主/预览测试输出及性能原始数据。只有全部必需项通过才写 **Go**；材料或旧系统缺失写 **未验**，视觉撕裂、包外读取、动作错路由或预算超限写 **No-Go**。用户对最终视觉是否达到“完全写实”保留验收权。

### T15 — 文档与候选交付（G4）

G3 通过后更新中英文 README 功能、API 参考、SDK/CLI、设计台账、预览指南、CHANGELOG 和本任务状态；审查 `git diff --check`、`git status --short`，清理临时文件。发行前按外仓不可变 revision 和锁文件流程运行 `make verify-plugin-release`。提交、推送、合并、发布均需另行授权。

## 4. 阶段门禁与状态规则

| 门禁 | 进入条件 | 必须看到的证据 | 失败处理 |
| --- | --- | --- | --- |
| G0 合同 | C-D01，T00 | 正反样本、预算、旧宿主回退、合同检查真实输出 | 不写正式 UI 节点。 |
| G1 通用纵向切片 | T01–T06 | 安全预检、两个 glb、原生画面/动作、构建单测 | 修渲染或资源闭环，不让插件仓做绕过。 |
| G2 宿主与预览 | T07–T09 | 同源渲染、真实 Dock 图、预览报告、旧布局回归 | 不用独立探针替代共享路径。 |
| G3 产品与系统 | T10–T14 | 真实媒体、连续旋转、视觉、AX/键盘、旧系统、性能 | No-Go 保留可用 2D 模式；触发 C-D01 退出条件时重新比较 B。 |
| G4 交付 | G3、T15 | 文档/锁文件/构建/差异、用户视觉结论 | 不标发布就绪。 |

任务状态只允许“待实施 / 进行中 / 已完成（附证据） / 未验（原因） / 阻塞（条件）”。计划、编译、离屏截图、真实面板、系统行为和用户视觉验收分别记，不能互相替代。
