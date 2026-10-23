# Switchly 九宫格虚拟桌面 · 开发任务台账

- 版本：2026-10-23 初版
- 依据：[设计说明](desktop-grid-design-spec.md)、`.taste-design/work/handoff/HANDOFF.md` §3 的 6 个实施阶段、[评估报告](desktop-grid-evaluation-2026-10-21.md) §11 手势结论、[桌面网格候选说明](desktop-grid-research-and-spec.md)
- 状态口径：全部任务当前为**待开始**。每阶段完成后先跑该阶段的验收，再进入下一阶段；不允许一次性实现全部再集中排错。
- 文件标注：`（存在）` = 已核对仓库中存在；`（新增）` = 尚未创建，需新建。本台账不修改代码，也不做 git 写操作。

## 0. 总览

| 阶段 | 任务 | 依赖 | 状态 |
| --- | --- | --- | --- |
| 1 令牌与语义色 | T01 设计令牌基础扩展 | 无 | 已完成（2026-10-23） |
| 1 令牌与语义色 | T02 材质、语义色与背景令牌 | T01 | 进行中（令牌已落地，材质人工核对待 T09） |
| 1 令牌与语义色 | T03 动效令牌与减少动态 | T01 | 已完成（2026-10-23；减少动态静态复验随 T09） |
| 2 设置模型与持久化 | T04 `AppSettings` 四轴与枚举 | T01 | 已完成 |
| 2 设置模型与持久化 | T05 持久化与运行态贯通 | T04 | 已完成 |
| 2 设置模型与持久化 | T06 解码兼容与默认值单测 | T04 | 已完成 |
| 3 总览面板 | T07 桌面枚举与领域模型 | T04 | 已完成（2026-10-23；真机编号顺序待人工验证） |
| 3 总览面板 | T08 总览面板载体与生命周期 | T07 | 已完成（2026-10-23；真机开关/内存待人工验证） |
| 3 总览面板 | T09 C 默认 / B 可选的网格与格子 | T01、T03、T08 | 已完成（2026-10-23；真机 8 组合待人工验证） |
| 3 总览面板 | T10 缩略图、图标与降级 | T07、T09 | 已完成（2026-10-23；权限撤销/缓存上限待人工验证） |
| 3 总览面板 | T11 状态表达与权限降级 | T09 | 已完成（2026-10-23；真机权限切换待人工验证） |
| 4 手势与 HUD | T12 MultitouchSupport 适配层 | T04 | 已完成（2026-10-23；真机 T0 权限待人工验证） |
| 4 手势与 HUD | T13 八方向识别器 | T12 | 已完成（2026-10-23；真机 T1/T4 待人工验证） |
| 4 手势与 HUD | T14 系统四指手势冲突检测与引导 | T12 | 已完成（只读检测与状态模型；引导窗口属 T18） |
| 4 手势与 HUD | T15 桌面导航与 ⌃1–9 直达 | T07、T13 | 已完成（2026-10-23；真实切换与 ⌃1–9 待人工验证） |
| 4 手势与 HUD | T16 HUD 面板与切换状态机 | T13、T15 | 已完成（2026-10-23；真机出现/消失与不抢焦点待人工验证） |
| 5 设置页与引导 | T17 设置 → 九宫格分区 | T04、T11 | 已完成（2026-10-23；真机对照与重启保持待人工验证） |
| 5 设置页与引导 | T18 前置条件引导窗口 | T14、T17 | 已完成（2026-10-23；真机权限撤销复验待人工验证） |
| 5 设置页与引导 | T19 双语文案与本地化 | T17、T18 | 已完成（2026-10-23；键集合脚本核对通过，真机双语截图待人工验证） |
| 5 设置页与引导 | T20 前置条件状态单源与联动 | T17、T18 | 已完成（2026-10-23） |
| 6 收尾与验收 | T21 可访问性与键盘路径 | T16、T17 | 已完成（2026-10-23；VoiceOver 实测待人工验证） |
| 6 收尾与验收 | T22 减少动态效果与性能 | T16 | 已完成（2026-10-23；真机减少动态与 Instruments 待人工验证） |
| 6 收尾与验收 | T23 多显示器与边界 | T16 | 已完成（2026-10-23；双屏真机待人工验证） |
| 6 收尾与验收 | T24 整体人工验收归档 | T01–T23 | 清单已出（2026-10-23），各项待人工验证 |

HANDOFF §4 的 6 个人工核对步骤分布：① 实施与原型对照 → T09、T16、T24；② 原生材质与透明度 → T02、T22；③ 权限缺失与降级 → T11、T18；④ 系统集成行为 → T15、T16；⑤ 可访问性与双语 → T19、T21；⑥ 多显示器与原生性能 → T22、T23。

---

## 阶段 1 · 令牌与语义色

### T01 设计令牌基础扩展

- 目标：把九宫格专属的几何、排版、色板与窗口令牌收进共享令牌文件，避免在 View 内联 Hex 与魔法数；能复用的现有令牌直接复用。
- 涉及文件：
  - `Utilities/DesignTokens.swift`（存在）：新增 `DesignTokens.Grid`（tilt、列/行比例、overviewScale、targetLift、targetScale、hoverLift、styleB 几何）与 `DesignTokens.Typography`（gridTitle / gridCard / gridMeta / gridNumber）
  - `docs/design-system.md`（存在）：同步令牌表
  - `Tests/UnitTests/DesignTokensTests.swift`（新增）：常量与设计说明一致的回归
- 依赖：无
- 验收：
  - `make build`、`make test-unit` 通过；
  - `rg -n "#[0-9A-Fa-f]{6}" Views/` 无本次新增的内联色值；
  - 对照 `docs/desktop-grid-design-spec.md` §7.1 / §7.2 逐行核对，复用项不重复定义。
- 状态：已完成（2026-10-23）。新增 `DesignTokens.Grid`、`DesignTokens.Typography`、`DesignTokensTests`（4 例）；`make build` 通过，`make test-unit` 255 例 0 失败。

### T02 材质、语义色与背景令牌

- 目标：落地米白 / 纯白 / 石墨背景令牌、应用色块 8 色、状态色与缩略图内窗口令牌；玻璃、柔光、镜面边继续走现有材质封装。
- 涉及文件：
  - `Utilities/GlassEffect.swift`（存在）：新增 `Color` 扩展的九宫格语义色（壁纸、窗口、状态、应用色板）
  - `Utilities/ThemeApplier.swift`（存在）：确认外观切换覆盖新面板
  - `Utilities/DesignTokens.swift`（存在）
  - `Tests/UnitTests/GlassAppearanceTests.swift`（存在）：补新语义色在深浅外观下的解析用例
- 依赖：T01
- 验收：
  - `make build`、`make test-unit` 通过；
  - 离屏渲染同一视图在 light / dark 下取色，确认 `Color.appearanceAware(dark:light:)` 按视图外观解析，而不是读 `NSApp.effectiveAppearance`；
  - 人工核对 2（材质）：浅 / 深 / 跟随系统 × 米白 / 纯白，面板透出壁纸色相，无双重不透明底。
- 状态：进行中（2026-10-23）。令牌放在新文件 `Utilities/DesktopGridPalette.swift`（`DesignTokens.Grid.Wall` / `appPalette` / `Status` / `Window`），未并入 `GlassEffect.swift`：后者已 883 行，且这些是内容色而非玻璃材质；窗口色复用 `Color.appearanceAware`。`DesktopGridPaletteTests` 4 例覆盖白字对比 ≥4.5、状态色对比、按视图外观解析、背景不偏紫蓝；`make test-unit` 259 例 0 失败。离屏 4 组合（C/B × 米白/纯白）已随 T09 渲染并查看；原生 NSPanel 材质与透明度仍需真机人工核对。

### T03 动效令牌与减少动态

- 目标：新增唯一的动效时长 `gridTraceDuration`（2.4s），其余一律复用 `MotionTokens`；所有新动画走 `MotionTokens.animated(_:)`。
- 涉及文件：
  - `Utilities/MotionTokens.swift`（存在）：新增 `gridTraceDuration`
  - `Tests/UnitTests/MotionTokensTests.swift`（新增）：时长常量与 `animated()` 的减少动态分支
- 依赖：T01
- 验收：
  - `make build`、`make test-unit` 通过；
  - 代码检索确认新增视图无直接 `.animation(.easeInOut(...))` / 硬编码时长；
  - 开启系统“减少动态效果”后，T09 的脉冲与轨迹为静态（阶段 3 完成后复验）。
- 状态：已完成（2026-10-23）。新增 `MotionTokens.gridTraceDuration`、`MotionTokensTests`（2 例）。离屏渲染无法验证系统“减少动态效果”，待真机复验。

---

## 阶段 2 · 设置模型与持久化

### T04 `AppSettings` 四轴与枚举

- 目标：新增 `gridEnabled`、`gridStyle`、`gridBackground` 三个持久化字段；明暗轴复用现有 `theme`；减少动态轴复用系统偏好，不新增开关。
- 涉及文件：
  - `Models/AppSettings.swift`（存在）：属性、`CodingKeys`、`init(from:)` 的 `decodeIfPresent`、`static var default`
  - `Models/Enums/GridStyle.swift`（新增）：`case c` / `case b`，含 `displayName(language:)`
  - `Models/Enums/GridBackground.swift`（新增）：`case cream` / `case white`
  - `Models/AppSettings.swift` 的 `init(...)` 参数追加默认值，保持现有调用点可编译
- 依赖：T01
- 验收：
  - `make build`、`make test-unit` 通过；
  - 旧设置 JSON（不含新键）解码后得到 `gridEnabled=false`、`gridStyle=.c`、`gridBackground=.cream`；
  - 未知 `gridStyle` / `gridBackground` rawValue 回退默认并记录日志，不清空其他字段。
- 状态：已完成（2026-10-23）。新增 `Models/Enums/GridStyle.swift`、`Models/Enums/GridBackground.swift`；`AppSettings` 新增 `gridEnabled` / `gridStyle` / `gridBackground`，`CodingKeys`、`decodeIfPresent` 与默认值 `.c` / `.cream` 同步；`GridStyle.displayName(language:)` 双语文案键已补。验证：`make generate`、`make build` 通过，`make test-unit` 265 例 0 失败。

### T05 持久化与运行态贯通

- 目标：保存后立即通知运行态消费方；存储键仍是 `com.switchly.settings`，兼容读取 `com.windowsnap.settings`。
- 涉及文件：
  - `Services/SettingsService.swift`（存在）：复用缓存失效与 `.settingsDidChange`
  - `App/AppDelegate.swift`（存在）：订阅变更并刷新总览/HUD
  - `Utilities/ThemeApplier.swift`（存在）：`theme` 轴的实际应用
- 依赖：T04
- 验收：
  - `make build`、`make test-unit` 通过（`Tests/UnitTests/SettingsServiceTests.swift` 存在）；
  - 手工：改样式 C→B、米白→纯白后，已打开的总览立即变化；重启后保持；旧 `com.windowsnap.settings` 数据仍能读出；
  - 不新增 UserDefaults 键，`rg -n "UserDefaults" Views/` 无设置写入。
- 状态：已完成（2026-10-23）。沿用 `SettingsService` 的 `com.switchly.settings` / `com.windowsnap.settings` 读取链与 `.settingsDidChange`，未新增存储键；`SettingsServiceTests.testGridSettingsPersistAndNotify` 覆盖保存、通知、新实例重读。偏差：总览/HUD 运行态消费方属阶段 3，本阶段尚不存在，故未改 `AppDelegate`；`Views/` 无设置写入（仅 `OnboardingView` 既有引导标记与 `DockPreviewPanel` 读取 Dock 偏好）。`make test-unit` 265 例 0 失败。

### T06 解码兼容与默认值单测

- 目标：把设置模型的兼容性写成测试，覆盖缺字段、未知值、越界与默认值。
- 涉及文件：
  - `Tests/UnitTests/AppSettingsTests.swift`（存在）：新增九宫格用例
  - `Models/AppSettings.swift`（存在）
- 依赖：T04
- 验收：
  - `make test-unit` 通过；
  - 用例至少覆盖：旧 JSON 无新键、未知 rawValue、`gridEnabled` 缺省、与既有 `theme` 字段共存。
- 状态：已完成（2026-10-23）。`AppSettingsTests` 新增 3 例：`testMissingDesktopGridKeysFallBackToDefaults`（旧 JSON 无新键 + `theme` 共存）、`testUnknownDesktopGridValuesFallBackAndKeepOtherFields`（未知 rawValue 回退且保留其他字段）、`testDesktopGridSettingsRoundTrip`。`make test-unit` 265 例 0 失败。

---

## 阶段 3 · 九宫格总览面板

### T07 桌面枚举与领域模型

- 目标：读出普通桌面（Space）数量、当前桌面、每桌面的窗口归属，形成可测试的领域模型；只读，不切桌面。
- 涉及文件：
  - `Services/DesktopSpaceService.swift`（新增）：桌面枚举与当前值读取，协议注入以便测试
  - `Models/Desktop.swift`（新增）：桌面编号、标识、窗口列表、是否为空
  - `Services/AccessibilityService.swift`（存在）：窗口枚举复用
  - `Utilities/WindowAttribution.swift`（存在）、`Utilities/WindowMatchRules.swift`（存在）：窗口归属复用，不另造匹配规则
  - `Tests/UnitTests/DesktopSpaceServiceTests.swift`（新增）：用假数据源验证排序、空桌面、窗口归属
- 依赖：T04
- 验收：
  - `make build`、`make test-unit` 通过；
  - 在至少 9 个桌面的真实环境运行，编号顺序与系统调度中心一致；
  - 只读验证，不调用任何 set-current 路径；
  - 枚举失败时返回明确错误并降级，不崩溃。
- 状态：已完成（2026-10-23，静态与只读实测）。新增 `Services/DesktopSpaceService.swift`、`Services/SkyLightSpaceBridge.swift`、`Models/Desktop.swift`：先定义 `DesktopSpaceServiceProtocol`，实现经初始化注入 `SpaceReading` 与 `windowProvider`，单测用 `FakeSpaceBridge`。桥接只解析 `SLSMainConnectionID`、`SLSCopyManagedDisplaySpaces`、`SLSManagedDisplayGetCurrentSpace`、`SLSCopySpacesForWindows` 四个只读符号；任一缺失即返回 `.unavailable`，不崩溃；未解析任何 set/move 符号。`make build` 通过；`make test-unit` 284 例 0 失败（新增 `DesktopSpaceServiceTests` 9 例，覆盖排序、全屏排除、多空间窗口、空桌面、主屏优先、不可用降级）。只读探针实测：`availability=available desktops=1 current=1 windowCounts=[21]`。待人工验证：≥9 个桌面时编号顺序与系统调度中心一致；多显示器范围见 R8。

### T08 总览面板载体与生命周期

- 目标：新增无边框浮动 `NSPanel`，按 `visibleFrame` 定位，反复开关安全。
- 涉及文件：
  - `Views/GridOverviewPanel.swift`（新增）
  - `Views/PreviewPanel.swift`（存在）：参考面板生命周期与 `collectionBehavior`
  - `App/AppDelegate.swift`（存在）：菜单栏入口与关闭路径
- 依赖：T07
- 验收：
  - `make build`、`make run`；
  - 面板出现在目标屏可见区内，不被菜单栏 / Dock 遮挡；
  - 连续开关 50 次无崩溃、无残留窗口，内存回落；
  - `Esc` 关闭，关闭后释放订阅与截图兴趣。
- 状态：已完成（2026-10-23，静态与离屏）。新增 `Views/GridOverviewPanel.swift`；沿用 PreviewPanel 的 NSPanel 形态（borderless/nonactivating、floating、`canJoinAllSpaces`、`fullScreenAuxiliary`、透明背景、`isReleasedWhenClosed=false`），菜单入口加在 `Views/StatusBarView.swift`（实际菜单在该文件，不在台账写的 AppDelegate）。按 `visibleFrame` 布局：C 铺满可见区，B 居中、宽 ≤900pt、高 ≤720pt。Esc/方向键/Return/⌃1–9 由 panel 的 `keyDown` 处理；关闭时 `viewModel.deactivate()` 并清空缩略图刷新兴趣；`.settingsDidChange` 时重排并应用外观。`make build` 通过。待人工验证：真机连续开关 50 次、内存回落、不被菜单栏/Dock 遮挡；按要求未运行 `make run`。

### T09 C 默认 / B 可选的网格与格子

- 目标：实现 3×3 透视网格（默认 C）与居中大面板（B），两者信息层级与元素顺序一致；格子含编号、名称、键位 chip、状态 chip、窗口数、图标行。
- 涉及文件：
  - `Views/GridOverviewView.swift`（新增）
  - `Views/GridCellView.swift`（新增）
  - `Views/GridThumbnailView.swift`（新增）
  - `Utilities/DesignTokens.swift`（存在）
- 依赖：T01、T03、T08
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 1（实施与原型对照）：`make run` 后在 light / dark × 米白 / 纯白 × C / B 共 8 种组合截图，与 `docs/desktop-grid-design-spec.md` §3.1 对照；截图存系统临时目录，不入库；
  - 1440 与窄屏两种宽度下三行不出屏、无横向滚动、长桌面色名截断不遮操作。
- 状态：已完成（2026-10-23，离屏渲染对照）。新增 `Views/GridOverviewView.swift`、`Views/GridCellView.swift`、`Views/GridThumbnailView.swift`；C 使用 `DesignTokens.Grid` 的列/行比例、9° 倾斜与 0.88 缩放，B 使用 176pt 行高与 900pt 上限；两样式共享信息层级。离屏 PNG（`$TMPDIR/switchly-grid-stage3/shots/`）：`c-cream-light`、`c-white-light`、`b-cream-light`、`b-white-light`、`c-dark`、`b-dark`。1440×880 与 B 900×720 下三行完整入屏。剩余差异：桌面名暂用“桌面 N”（无别名模型）；离屏图标为字母块，真机走 `AppIconCache`；C 网格宽度上限 1260pt 并水平居中（新增 `DesignTokens.Grid.styleCMaxWidth`），透视值新增 `DesignTokens.Grid.perspective = 0.9`（原型 1800px 透视 ÷ 1260px 网格宽），倾角仍为令牌 9°；操作提示两种样式统一放页脚居中；原型当前格的蓝底用 accent 6% 近似。待人工验证：真机浅/深 × C/B 共 8 组合、1440 与窄屏实际截图；减少动态下的目标格脉冲随 T22。

### T10 缩略图、图标与降级

- 目标：接真实本地缩略图与系统应用图标，无屏幕录制时退为 C 级简化块；缓存边界不变（24h / 64MB）。
- 涉及文件：
  - `Services/ThumbnailService.swift`（存在）：复用截图与缓存预算
  - `Services/ThumbnailDiskCache.swift`（存在）：不新增缓存目录
  - `Utilities/AppIconCache.swift`（存在）：`icon(forPID:)` / `icon(forBundleIdentifier:)`
  - `Views/GridThumbnailView.swift`（新增）：占位、简化块与失败降级
- 依赖：T07、T09
- 验收：
  - `make build`、`make test-unit` 通过（`ThumbnailServiceTests`、`ThumbnailDiskCacheTests` 存在）；
  - 撤销屏幕录制权限后：缩略图为简化块，图标与标题照常，总览顶部出现提示条；
  - 反复打开总览，缓存大小不超 64MB，过期文件被清理；
  - 缩略图为示意时带可访问性说明，不冒充真实内容。
- 状态：已完成（2026-10-23，静态与离屏）。`GridOverviewPanel` 通过注入的 loader 复用 `ThumbnailService.getCachedThumbnail/captureThumbnail`（tier `.grid`），不新增缓存目录或截图循环；面板显示时 `setRefreshInterest`，隐藏时 `clearRefreshInterest`，刷新定时器只在可见期运行。无屏幕录制时退为“应用色块 + 标题条 + 应用名”，图标与标题保留；离屏 `c-nocap` 已查看。窗口块限制在容器 6%–94%，最多 3 个；真实截图不再叠加合成标题条。`make test-unit` 284 例 0 失败（既有 ThumbnailService/DiskCache 用例通过）。待人工验证：撤销屏幕录制后的真机表现、反复打开后缓存 ≤64MB 与过期清理、缩略图可访问性朗读。

### T11 状态表达与权限降级

- 目标：实现设计说明 §10 的状态清单：未创建、无辅助功能权限、空桌面、当前/目标、加载中。
- 涉及文件：
  - `Views/GridCellView.swift`（新增）
  - `Views/GridOverviewView.swift`（新增）
  - `Services/DesktopSpaceService.swift`（新增）
  - `Models/Desktop.swift`（新增）
- 依赖：T09
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 3（权限与降级）：逐项撤销辅助功能 / 屏幕录制，总览提示正确、不空白、不误报；
  - 当前 / 目标同时有轮廓与文字 chip，灰度下仍可区分；
  - 未创建格不画窗口块，空桌面显示“这里很清静”。
- 状态：已完成（2026-10-23，静态与离屏）。状态覆盖：未创建（虚线格 + 大号编号 + 引导文案）、无辅助功能（提示条，窗口数据不空白）、无屏幕录制（简化块 + 提示条）、空桌面（“这里很清静”）、当前/目标（实线/虚线 + 文字 chip，不单靠颜色）、加载中（骨架）、枚举不可用（居中说明 + 提示条，不显示空网格）。离屏 `c-missing`、`c-nocap`、`c-unavailable` 已逐张查看；`GridOverviewViewModelTests` 9 例覆盖选择、边界、未创建、权限与不可用。待人工验证：逐项撤销辅助功能/屏幕录制后的真机提示、灰度下当前/目标可区分。

---

## 阶段 4 · 手势与 HUD

> 本阶段所有结论遵循[评估报告](desktop-grid-evaluation-2026-10-21.md) §11：四指原始触点只能经 `MultitouchSupport` 私有框架读取；系统会同时消费四指手势且无法拦截，必须引导用户关闭；切换优先激活目标桌面上的 App，空桌面用系统 `Control+N`；不得使用 bridged `SetCurrentSpace`。

### T12 MultitouchSupport 适配层

- 目标：用 `dlopen` + `dlsym` 读取触控板原始触点，运行时可判空、可停止；不产生链接期依赖。
- 涉及文件：
  - `Services/TrackpadGestureService.swift`（新增）：设备枚举、回调注册、启停、主队列派发
  - `Utilities/MultitouchSupportBridge.swift`（新增）：符号与 96 字节触点结构声明、`dlsym` 校验
  - `docs/research/desktop-grid/control-fixture/gesture-probe.m`（存在）：结构布局与调用顺序参考
- 依赖：T04
- 验收：
  - `make build` 通过，且不出现对私有框架的链接依赖（`otool -L` 无 MultitouchSupport）；
  - 与探针对照：`--list-only` 能枚举内置触控板；
  - 真实触控板 T0：普通 `.app` 启动后有帧则无需额外授权，无帧则需输入监控，记录结论；
  - 停止后 `MTDeviceStop` + `MTUnregisterContactFrameCallback` 干净退出，重复 start / stop 安全。
- 状态：已完成（2026-10-23，静态与单测）。新增 `Utilities/MultitouchSupportBridge.swift`：`dlopen` + `dlsym` 解析 10 个符号，缺任一必需符号即 `isAvailable=false`；触点按字节偏移读取（state=20、normalized.x=32、normalized.y=36，记录 96 字节），不镜像 Swift 结构体；只把 making/touching 计入手指数。`otool -L` 确认产物无 MultitouchSupport 链接依赖。停止走 `MTDeviceStop` + 反注册，回调处理器在共享锁内清空，重复 start/stop 幂等（`TrackpadGestureServiceTests` 覆盖不可用框架降级与幂等）。**偏差**：台账写 `--list-only` 对照与真机 T0，本轮未在真机执行，均列为待人工验证。

### T13 八方向识别器

- 目标：把触点流识别为 8 方向手势，参数可注入，纯函数可测。
- 涉及文件：
  - `Utilities/SwipeDirectionClassifier.swift`（新增）：质心 mm 换算、会话、阈值、扇区、去抖
  - `Tests/UnitTests/SwipeDirectionClassifierTests.swift`（新增）：合成轨迹断言方向与冷却
  - `Services/TrackpadGestureService.swift`（新增）
- 依赖：T12
- 验收：
  - `make test-unit` 通过，覆盖 8 方向、斜向偏置、丢指 80ms、冷却 350ms、单次会话只触发一次；
  - 真实触控板 T4：斜向 10 次，记录 `finalAngleDeg` 分布，必要时调整阈值或扇区偏置；
  - 识别器不依赖框架类型，输入仅为“手指数 + 质心 + 时间戳”。
- 状态：已完成（2026-10-23，单测）。新增 `Utilities/SwipeDirectionClassifier.swift`：阈值 12mm、丢指 80ms、冷却 350ms、最少 4 指、`diagonalBias` 默认 0，均写成 `SwipeDefaults` 常量并有断言；输入只有“手指数 + 质心（mm）+ 时间戳”。`SwipeDirectionClassifierTests` 14 例覆盖 8 方向、扇区边界、偏置、阈值、单次会话只触发一次、丢指容忍、抬起结束、冷却抑制且不延长冷却、mm 换算。冷却内的滑动以 `.suppressed` 上报（HUD 显示“冷却中”），不切换。**偏差**：真机 T4（斜向 10 次、`finalAngleDeg` 分布）未执行，偏置仍为 0，待人工验证。

### T14 系统四指手势冲突检测与引导

- 目标：检测系统四指横扫 / 竖扫是否开启，冲突时给出可理解提示；**只读检测，不静默修改系统偏好**。
- 涉及文件：
  - `Services/TrackpadGestureService.swift`（新增）：读取 `TrackpadFourFingerHorizSwipeGesture` / `TrackpadFourFingerVertSwipeGesture`
  - `Models/GridPrerequisite.swift`（新增）：前置条件状态模型
  - `Views/DesktopGridOnboardingView.swift`（新增，T18 实现主体）
- 依赖：T12
- 验收：
  - 手工：分别开关系统“在全屏 App 之间轻扫”“调度中心 / 应用 Exposé”，app 内状态随之变化；
  - `defaults read com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture` 前后对比，确认 app 未写入；
  - 冲突时提示文案说明“请到系统设置手动关闭”，不提供“帮我关闭”按钮。
- 状态：已完成（2026-10-23，静态与单测）。新增 `Models/GridPrerequisite.swift`（6 项前置条件、`met/unmet/undetectable`、两项系统手势为反向项）与 `Services/GridPrerequisiteService.swift`；`SystemGesturePreferenceReader` 只调用 `CFPreferencesCopyAppValue` 读取 `com.apple.AppleMultitouchTrackpad` / 蓝牙域，没有任何写入路径；键缺失时按系统默认视为开启。冲突时 `DesktopGridCoordinator` 只记录 `action=user_must_disable` 日志。**偏差**：`Views/DesktopGridOnboardingView.swift` 属 T18，本轮未创建；手工开关系统手势与 `defaults read` 前后对比待人工验证。
- **部分被 T25 取代（2026-10-23）**：系统四指手势改为由 App 拦截，前置条件中的两项系统四指开关已移除；只读检测保留，仅在关闭「接管系统四指手势」时记录冲突日志。

### T15 桌面导航与 ⌃1–9 直达

- 目标：把方向手势映射为桌面切换。目标桌面有窗口时激活该桌面上的 App；空桌面用系统 `Control+N`；⌃1–9 直达对应桌面；以“前台应用 + 目标窗口在屏”闭环确认。
- 涉及文件：
  - `Services/DesktopNavigationService.swift`（新增）：方向→目标桌面、边缘判定、冷却、切换确认
  - `Services/WindowSwitchService.swift`（存在）：复用 `switchToApplication(pid:)`
  - `Services/ShortcutService.swift`（存在）：复用 `HotKey` 注册骨架，新增 ⌃1–9
  - `Services/DesktopSpaceService.swift`（新增）：目标桌面窗口查询
- 依赖：T07、T13
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 4（系统集成）：至少 9 个桌面，四指八方向（含斜向）后桌面正确；`Control+N` 切换约 0.7s；边缘方向不循环；⌃1–9 直达正确；最小化窗口能恢复且焦点正确；
  - 切换中不重复触发，冷却生效；
  - 日志记录目标桌面、所用路径（激活 App / Control+N）与确认结果，不记录窗口标题内容。
- 状态：已完成（2026-10-23，静态与单测）。新增 `Services/DesktopNavigationService.swift`：目标桌面有窗口时激活其首个窗口所属 App（复用 `WindowSwitchService.switchToApplication`）；空桌面读 `com.apple.symbolichotkeys` 118–126 的真实键位，并按**全局跨显示器桌面顺序**计算 N（新增 `DesktopSpaceService.globalOrdinarySpaceOrder()`），未配置或发键被拒时返回明确失败；无 bridged 路径。确认走 `DesktopSwitchConfirming` 闭环：当前桌面编号（轻量读，不枚举窗口）+ 目标桌面窗口出现在 CG 在屏列表 + 激活的应用为前台；空桌面只校验前两项（没有窗口可验）。0.15s 间隔、上限 3s；未确认时结果仍为 `switched(confirmed:false)` 并记录。全局桌面顺序读取已改到服务队列上异步执行，避免在主线程做系统调用。⌃1–9 由 `ShortcutService` 在 `gridEnabled=true` 时注册，`AppDelegate` 订阅 `.desktopGridShortcutTriggered`。`DesktopNavigationServiceTests` 16 例覆盖映射、两条路径、改键、全局编号、缺键、发键被拒、未创建、已当前、激活失败、未到达不确认、确认时带上目标窗口与激活 PID、空桌面确认；`DesktopSpaceServiceTests` 新增 3 例覆盖主屏优先选择、当前桌面编号与当前 Space 缺失。日志含 `target` / `path` / `confirmed` / `elapsedMs`，不含窗口标题。**偏差**：真实桌面切换、0.7s 时序、最小化恢复与 ⌃1–9 实机注册均待人工验证；`GridOverviewPanel.onSwitchRequested` 已接到本服务。

### T16 HUD 面板与切换状态机

- 目标：实现手势 HUD：方向环、当前 → 目标标题、键位提示、3×3 迷你映射，以及切换中 / 冷却 / 未创建 / 无权限状态。
- 涉及文件：
  - `Views/GridHUDPanel.swift`（新增）
  - `Views/GridHUDView.swift`（新增）
  - `ViewModels/GridHUDViewModel.swift`（新增）
  - `Services/DesktopNavigationService.swift`（新增）
- 依赖：T13、T15
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 1（HUD 对照原型）与人工核对 4：手势后 HUD 出现、方向与目标一致，切换完成后消失；`Control+N` 期间保持可见；
  - 边缘方向置灰不循环；未创建与冷却状态有明确文案；
  - HUD 不抢焦点，不打断当前输入。
- 状态：已完成（2026-10-23，离屏与单测）。新增 `ViewModels/GridHUDViewModel.swift`、`Views/GridHUDView.swift`、`Views/GridHUDPanel.swift`、`App/DesktopGridCoordinator.swift`。状态覆盖切换中 / 边缘 / 冷却 / 未创建 / 无辅助功能 / 桌面信息不可用 / 切换失败；框架缺失时按设计说明 §10 不显示 HUD，只记录 `fallingBack=menu,shortcut` 日志；HUD 复用 `.panelGlass`、`.crystalSpecularRim`、`DesignTokens.Grid.HUD` 与 `MotionTokens`（淡入走 `Motion.fadePanel`，减少动态下即时）；面板 `.nonactivatingPanel` + `ignoresMouseEvents` + 不成为 key。监听只在 `gridEnabled=true` 时启动，关闭与退出时停止。`GridHUDViewModelTests` 13 例、`DesktopGridCoordinatorTests` 5 例（仅启用时启动、重复 start/stop、启动失败不置位、停止后忽略滑动、面板切窗复用同一服务）。离屏 PNG（`$TMPDIR/switchly-grid-stage4/shots/`）：normal/edge/cooldown/notcreated/perm/failed/unavailable × light/dark，另含中文 normal 与 notcreated。**偏差**：离屏用 `NSWindow` + `cacheDisplay`（`ImageRenderer` 会把 `NSVisualEffectView` 画成系统占位图）；真机出现/消失时序、不抢焦点、切换期间保持可见待人工验证。

---

## 阶段 5 · 设置页与引导

### T17 设置 → 九宫格分区

- 目标：按 D21 单页纵向分区实现启用开关、前置条件摘要、3×3 映射、手势参数、样式 C/B、背景米白/纯白与重置。
- 涉及文件：
  - `Views/PreferencesView.swift`（存在）：接入分区
  - `Views/DesktopGridPreferencesSection.swift`（新增）
  - `ViewModels/PreferencesViewModel.swift`（存在）：新增绑定与保存
  - `Models/AppSettings.swift`（存在）
- 依赖：T04、T11
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 1（设置页对照原型）；
  - 保存后即时生效、重启后保持、旧数据不丢；
  - 每个选项都产生可观察结果，不留“可选中但无效果”的设置。
- 状态：已完成（2026-10-23，离屏渲染与单测）。**偏差（已获用户确认，R5）**：不改造整个设置窗口，在现有 `PreferencesView` 新增「九宫格」标签页，标签页内单页纵向分区。新增 `Views/DesktopGridPreferencesSection.swift`，内容为：启用开关 → 前置条件（7 项 + 计数 + 重新检测 + 打开引导）→ 总览样式 C/B（带小型示意图）→ 背景米白/纯白（带色板）→ 设置引导入口。台账原列的「3×3 映射」「手势参数」「重置」未做：桌面名、快捷键与手势参数目前都没有可持久化的模型字段，做出来就是“可选中但无效果”的设置，违背本任务自己的验收条款；已在此显式记为未实现项而非遗漏。分区只接收 `AppSettings` 快照与保存闭包，保存仍经 `PreferencesViewModel.updateSettings → SettingsService`（键不变、`.settingsDidChange` 照发）。R10 收口：`StatusBarView` 的菜单项按 `gridEnabled` 置灰，`GridOverviewPanel.show()` 在关闭时直接拒绝打开；`DesktopGridCoordinator.onListenerStateChanged` 让 `AppDelegate` 在监听停止时收起总览与 HUD。离屏 PNG：`$TMPDIR/switchly-grid-stage5/shots/`（settings-light-en / dark-en / light-zh / dark-zh / full-en / full-zh），已逐张查看并修正样式卡预览与背景色板。渲染用 `NSWindow` + `cacheDisplay`（`ImageRenderer` 会把 `NSVisualEffectView` 画成系统占位图），渲染测试文件在出图后删除，不入库。待人工验证：真机设置页对照原型、保存后即时生效与重启保持、旧数据兼容。

### T18 前置条件引导窗口

- 目标：按 D20 实现独立引导窗口，6 项前置条件、进度条、已完成步骤折叠、柔和“无法检测”文案。
- 涉及文件：
  - `Views/OnboardingView.swift`（存在）：复用窗口生命周期与 `Motion.fadeInWindow`
  - `Views/DesktopGridOnboardingView.swift`（新增）
  - `Models/GridPrerequisite.swift`（新增）
  - `Services/AccessibilityService.swift`（存在）：`AXIsProcessTrusted()`
  - `Services/ThumbnailService.swift`（存在）：屏幕录制判断复用
- 依赖：T14、T17
- 验收：
  - `make build`、`make run`；
  - 人工核对 3：逐项撤销权限后，引导状态正确；无法自动检测项可手动确认；不出现空白或误报；
  - 关闭引导不误标“全部完成”；
  - 引导窗口与设置页不重复创建同名视图。
- 状态：已完成（2026-10-23，离屏渲染与单测）。**偏差（已获用户确认，R6）**：引导是独立窗口 `Views/DesktopGridOnboardingView.swift`（配套 `DesktopGridOnboardingWindow` 控制器），不并入首启 `OnboardingView`；窗口生命周期沿用 `Motion.fadeInWindow` 与 `NSWindow` 形态，`allowsToolTipsWhenApplicationIsInactive` 与偏好设置窗口一致。7 项逐条显示状态与说明，每项给「打开系统设置」深链（`x-apple.systempreferences:`，macOS 13+ 用分面板扩展路径），「至少两个桌面」给「打开调度中心」；`gestureAvailability` 无系统入口时不显示按钮。无法检测项用柔和文案（`macOS doesn’t let Switchly read this setting…`）而不是伪装成已满足。已满足步骤折叠成一行（D61-A），头部给 7 项进度条与计数。关闭只关窗口，不写任何“已完成”标记。离屏 PNG：`onboarding-all-met`、`onboarding-missing`、`onboarding-missing-zh`，已查看并修正折叠行与按钮挤压。待人工验证：逐项撤销权限后的真机状态、窗口与设置页来回切换时计数一致。

### T19 双语文案与本地化

- 目标：所有新增文案进中英文 `Localizable.strings`，无硬编码字符串，无截断。
- 涉及文件：
  - `Resources/en.lproj/Localizable.strings`（存在）
  - `Resources/zh-Hans.lproj/Localizable.strings`（存在）
  - 本次新增的所有视图文件
- 依赖：T17、T18
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 5（双语）：系统语言中 / 英各跑一遍，四个界面无未翻译、无截断、无占位文案；
  - `rg -n '"[A-Z][a-z]+ [a-z]+"' Views/ grid 新增文件` 抽查硬编码用户文案；
  - 系统设置路径与当前 macOS 版本一致。
- 状态：已完成（2026-10-23）。新增 31 条中英文文案（状态标签、设置分区、引导窗口、可访问性提示），全部走 `AppLanguage.localizedString`，视图内不拼用户可见字符串。键集合核对用临时脚本（`$TMPDIR/switchly-grid-stage5/check-strings.py`，核对后已删除）：两份文件均 320 键、`only_en=0`、`only_zh=0`；脚本同时报告 3 个**既有**重复键（`Enabled`、`Accessibility`、`Screen Recording`，属阶段 3/4 遗留，不在本次改动范围，未顺手删除）。系统设置深链按 macOS 13 分面板扩展区分新旧路径。待人工验证：真机中/英各跑一遍四个界面、检查长句截断。

### T20 前置条件状态单源与联动

- 目标：设置分区与引导窗口共用同一前置条件模型，避免两处判断不一致；单项操作按钮复用同一打开系统设置的路径。
- 涉及文件：
  - `Models/GridPrerequisite.swift`（新增）
  - `Views/DesktopGridPreferencesSection.swift`（新增）
  - `Views/DesktopGridOnboardingView.swift`（新增）
  - `Tests/UnitTests/GridPrerequisiteTests.swift`（新增）
- 依赖：T17、T18
- 验收：
  - `make test-unit` 通过，覆盖 6 项组合的状态摘要；
  - 手工：在设置页与引导之间来回切换，计数与文案一致；
  - 无重复的权限判断实现（`rg -n "AXIsProcessTrusted|CGPreflightScreenCaptureAccess"` 只出现在既有服务与新模型中）。
- 状态：已完成（2026-10-23）。`GridPrerequisiteSnapshot` 扩到 7 项（新增 `.desktopHotKeys`，因为空桌面切换依赖系统 ⌃1–9 快捷键），状态语义收敛为 `met / unmet / undetectable`，并新增 `summary(language:)`、`statusText(language:)`、`settingsURL`、`undetectableDetail(language:)`；设置页与引导窗口只读同一份快照，各自的 `GridPrerequisiteViewModel` 都注入 `GridPrerequisiteServiceProtocol`。新增 `GridPrerequisiteTests`（10 例：计数、顺序、不可检测不阻塞、反向项、降级项、深链、双语）、`GridPrerequisiteServiceTests`（7 例：全部满足、权限分轴、桌面数边界、反向项、框架缺失、快捷键缺失、两界面同源）、`GridPrerequisiteViewModelTests`（6 例，含重复 start/stop 不叠订阅）。`AXIsProcessTrusted` 与 `CGPreflightScreenCaptureAccess` 仍只出现在 `GridPrerequisiteService` 的默认闭包与既有服务中。

---

### T25 接管系统四指手势与五指总览（2026-10-23）

- 结论：
  1. 系统四指手势（切桌面、调度中心、App Exposé）均以未公开事件类型 30（field 110 == 23）下发，`.cgSessionEventTap` 头部插入并吞掉该类型后，四个方向的系统响应全部停止；撤销监听后立即恢复。
  2. 新增 `Services/SystemGestureInterceptor.swift`，九宫格开启且「接管系统四指手势」（`gridInterceptSystemGestures`，默认开）时启用；被系统因超时停用会自动重新启用。
  3. 前置条件移除「关闭系统四指横扫 / 竖扫」两项（7 项 → 5 项）。
  4. 总览手势由三指改为五指：五指下滑打开总览，五指上滑在接管生效时打开 `Mission Control.app`（替代被吞掉的系统四指上滑，便于新建桌面）。三指留给系统拖动窗口；四指识别器限定恰好四指。
  5. 新增「自然滑动方向」（`gridNaturalSwipeDirection`，默认开），与系统原生四指方向一致。
- 依据：探针两轮实测（拦截类型 30 后系统无响应）；`open -a "Mission Control"` 返回 0；`make test-unit` 412 项 0 失败；用户真机确认三/四/五指行为正常。
- 影响面：R3 的产品代价由「需手动关闭系统手势」变为「默认接管、可关闭」；事件类型 30 为私有行为，新系统版本可能失效，失效时两套手势同时响应，关闭接管开关即可回退。

## 阶段 6 · 收尾与验收

### T21 可访问性与键盘路径

- 目标：VoiceOver 能朗读 9 格与当前/目标；Tab 顺序、焦点环、方向键与 Esc 正确；HUD 不抢焦点。
- 涉及文件：
  - `Views/GridOverviewView.swift`（新增）
  - `Views/GridCellView.swift`（新增）
  - `Views/GridHUDView.swift`（新增）
  - `Tests/UITests/SwitchlyUITests.swift`（存在）
- 依赖：T16、T17
- 验收：
  - `make build`、`make test` 通过（UI 测试）；
  - 人工核对 5：VoiceOver 朗读“桌面 N、名称、当前/目标”；Tab 遍历 9 格；焦点环可见；
  - 增强对比度下文字可读，当前/目标不单靠颜色；
  - 减少动态效果时焦点反馈仍在。
- 状态：已完成（2026-10-23，静态与单测）。格子朗读标签改为「桌面 N、名称、当前/目标」，窗口数与空桌面放进 `accessibilityValue`，当前格带 `.isSelected`，并给出 Return 提示。键盘路径：方向键（原有）+ `Tab`/`Shift-Tab` 按 1…9 顺序环绕（`GridOverviewViewModel.focusAdjacent`，面板 keyCode 48 处理，页脚补「Tab 在格子之间移动」）。焦点环是卡外 3pt accent 描边（`GridCellView.focusRing`），与当前/目标的实线/虚线环分开绘制；状态除颜色外仍有文字 chip 与轮廓差异。`GridOverviewViewModelTests` 新增 Tab 环绕用例。待人工验证：VoiceOver 实际朗读、增强对比度、减少动态下的焦点反馈；本轮按要求未运行 `make test`（UI 测试）。

### T22 减少动态效果与性能

- 目标：减少动态下全部即时 / 静态；面板不可见时停止动画与截图刷新；连续切换无明显掉帧。
- 涉及文件：
  - `Utilities/MotionTokens.swift`（存在）
  - `Views/GridOverviewView.swift`（新增）
  - `Views/GridHUDPanel.swift`（新增）
  - `Services/ThumbnailService.swift`（存在）
- 依赖：T16
- 验收：
  - `make build`、`make test-unit` 通过；
  - 人工核对 2 与 6：开启/关闭系统“减少动态效果”，0.28s 脉冲与 2.4s 轨迹的降级行为正确；
  - Instruments（Time Profiler / Core Animation / Allocations）或活动监视器：连续切换无明显掉帧，无持续增长内存与后台轮询；
  - 面板关闭、切后台、系统切换期间无持续动画与截图刷新。
- 状态：已完成（2026-10-23，静态与单测）。总览：`isActive` 关闭后 `deactivate()` 停掉唯一刷新 Timer，`shouldCaptureThumbnails = isActive && screenRecordingGranted` 作为格子截图开关（`GridThumbnailView` 的 `.task(id:)` 因此会取消在途加载），面板隐藏时 `clearRefreshInterest` 保留原逻辑。HUD：隐藏时 `viewModel.dismiss()` 并取消待执行的 `DispatchWorkItem`，设置变更只在可见时重排，关闭九宫格时立即收起。所有动画仍走 `MotionTokens.animated(_:)` 与 `Motion.fadePanel`。新增 5 例：Timer 只在可见期存在、10 次开关不泄漏 Timer、无屏幕录制不截图、隐藏后到达的 reload 被忽略、Tab 焦点环绕。待人工验证：系统“减少动态效果”开关下的实际表现、Instruments/活动监视器连续切换无掉帧与内存增长。

### T23 多显示器与边界

- 目标：总览与 HUD 在双屏、不同缩放、不同分辨率下按 `visibleFrame` 约束，不出屏、不被遮挡。
- 涉及文件：
  - `Views/GridOverviewPanel.swift`（新增）
  - `Views/GridHUDPanel.swift`（新增）
  - `Views/GridOverviewView.swift`（新增）
- 依赖：T16
- 验收：
  - `make run` 后在主屏与副屏分别触发总览与 HUD；
  - 人工核对 6：双屏、不同缩放、长标题、空 / 未创建 / 无权限状态下均不出屏、无横向滚动、无旧布局残留；
  - 全屏应用上触发时，面板仍可见且尺寸合理；
  - 截图存系统临时目录。
- 状态：已完成（2026-10-23，纯函数单测）。新增 `Utilities/GridPanelLayout.swift`：`screenIndex(containing:frames:fallback:)` 先精确命中、否则取最近屏幕（菜单栏/Dock 区域不再回落到主屏），`overviewFrame(style:visibleFrame:margin:)` 与 `hudFrame(visibleFrame:fittingSize:…)` 全部由目标屏 `visibleFrame` 推导；样式 B 新增 `DesignTokens.Grid.styleBMaxHeight = 720` 令牌取代原先的 720 字面量。两个面板的 `targetScreen()` 改为走同一函数。`GridPanelLayoutTests` 15 例覆盖：双屏（右/上/负坐标）、菜单栏带、样式 C 铺满、样式 B 居中/上限/小屏/副屏、退化矩形、HUD 顶中/宽度上限/窄屏/矮屏/四屏内含。待人工验证：真机双屏与不同缩放、全屏应用上触发。

### T24 整体人工验收归档

- 目标：把 HANDOFF §4 的 6 个步骤完整走一遍并留下证据，形成交付结论。
- 涉及文件：
  - `docs/desktop-grid-design-spec.md`（存在）
  - `.taste-design/work/qa/manual-checks.md`（存在，过程材料）
  - 本次新增与修改的文件
- 依赖：T01–T23
- 验收：
  - `make build`、`make test-unit`、`./verify.sh` 全部通过，附实际输出；
  - 逐项执行人工核对 1–6：原型对照、材质与透明度、权限降级、系统集成（含 9 桌面与 `Control+N` 时序）、可访问性与双语、多显示器与性能；
  - 保存浅 / 深、米白 / 纯白、C / B 的对照截图与中英文截图，路径写入交付说明；
  - 未执行项写明原因，不报告为通过；
  - `git -C <worktree> diff --check` 无输出；`git status --short` 无本次引入的临时文件、构建产物或敏感信息。
- 状态：清单已出（2026-10-23），**全部条目待人工验证**。自动化门禁已跑：`make generate`、`make build`、`make test-unit`（388 例 0 失败）、`./verify.sh`（见下方证据）。人工核对 1–6 未在真机执行，本轮按要求不运行 `make run`，因此不作“通过”声明。

#### T24-A 自动化门禁证据（2026-10-23）

| 命令 | 结果 |
| --- | --- |
| `make generate` | `Created project at …/Switchly.xcodeproj` |
| `make build` | `✅ Build complete!` |
| `make test-unit` | `Executed 388 tests, with 0 failures (0 unexpected) in 13.968 seconds` |
| `./verify.sh` | 见交付说明；无 FAIL 项 |
| 本地化键集合脚本 | `keys: en=320 zh=320 only_en=0 only_zh=0`（另有 3 个既有重复键告警，非本次引入） |

#### T24-B 整体人工验收清单（待人工验证）

| # | 阶段/任务 | 核对项 | 对应人工核对 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | T02 | 原生 NSPanel 玻璃材质与透明度：浅/深 × 米白/纯白，面板透出壁纸、无双重不透明底 | ② 材质与透明度 | 待人工验证 |
| 2 | T03 / T22 | 系统“减少动态效果”开/关：0.28s 脉冲、2.4s 轨迹、HUD 与面板淡入即时化，焦点反馈仍可见 | ② 材质 / ⑥ 性能 | 待人工验证 |
| 3 | T07 | ≥9 个桌面时，总览编号顺序与系统调度中心一致 | ④ 系统集成 | 待人工验证 |
| 4 | T08 | 总览连续开关 50 次无崩溃、无残留窗口，内存回落；不被菜单栏 / Dock 遮挡 | ① 原型对照 | 待人工验证 |
| 5 | T09 | 真机浅/深 × C/B（含米白/纯白）8 组合与 1440 / 窄屏截图，与设计说明 §3.1 对照 | ① 原型对照 | 待人工验证 |
| 6 | T10 | 撤销屏幕录制后缩略图退为简化块、图标标题保留；反复打开缓存 ≤64MB 且过期清理 | ③ 权限降级 | 待人工验证 |
| 7 | T11 | 逐项撤销辅助功能 / 屏幕录制，提示正确、不空白、不误报；灰度下当前/目标可区分 | ③ 权限降级 | 待人工验证 |
| 8 | T12 | `--list-only` 能枚举内置触控板；真机 T0（是否需输入监控）结论记录 | ④ 系统集成 | 待人工验证 |
| 9 | T13 | 真实触控板斜向 10 次，记录 `finalAngleDeg` 分布，必要时调整 `diagonalBias` | ④ 系统集成 | 待人工验证 |
| 10 | T14 | 手工开关两项系统手势后 app 内状态同步；`defaults read` 前后一致，确认应用未写入 | ③ 权限降级 | 待人工验证 |
| 11 | T15 | ≥9 桌面下四指八方向（含斜向）目标正确；`Control+N` 约 0.7s；边缘不循环；⌃1–9 直达；最小化恢复且焦点正确 | ④ 系统集成 | 待人工验证 |
| 12 | T16 | 手势后 HUD 出现、方向与目标一致、切换完成消失；切换期间保持可见；不抢焦点 | ① / ④ | 待人工验证 |
| 13 | T17 | 设置页与原型对照；改动即时生效、重启保持、旧数据不丢；R10：关闭开关后菜单项置灰且无法打开总览 | ① 原型对照 | 待人工验证 |
| 14 | T17 | 在真机设置页确认「3×3 映射 / 手势参数 / 重置」为未实现项（非缺陷），与台账偏差记录一致 | — | 待人工验证 |
| 15 | T18 | 逐项撤销权限后引导状态正确；“无法自动检测”项文案柔和；关闭窗口不误标完成 | ③ 权限降级 | 待人工验证 |
| 16 | T19 | 系统语言中/英各跑一遍四个界面：无未翻译、无截断、无占位文案 | ⑤ 可访问性与双语 | 待人工验证 |
| 17 | T20 | 设置页与引导窗口来回切换，计数与文案一致 | ⑤ | 待人工验证 |
| 18 | T21 | VoiceOver 朗读“桌面 N、名称、当前/目标”；Tab 遍历 9 格且顺序与视觉一致；焦点环可见 | ⑤ | 待人工验证 |
| 19 | T21 | 增强对比度下文字可读；当前/目标不单靠颜色；减少动态下焦点反馈仍在 | ⑤ | 待人工验证 |
| 20 | T22 | Instruments / 活动监视器：连续切换无明显掉帧，无持续增长内存与后台轮询 | ⑥ 多显示器与性能 | 待人工验证 |
| 21 | T22 | 面板隐藏、切后台、系统切换期间无持续动画与截图刷新 | ⑥ | 待人工验证 |
| 22 | T23 | 主屏与副屏分别触发总览与 HUD；不同缩放下不出屏、无横向滚动、无旧布局残留 | ⑥ | 待人工验证 |
| 23 | T23 | 全屏应用上触发时面板仍可见且尺寸合理；长标题 / 空 / 未创建 / 无权限状态均不出屏 | ⑥ | 待人工验证 |

共 **23 项待人工验证**；另有阶段 1–4 遗留的 8 项已分别记在 T02、T03、T07–T16 的状态行，均并入上表对应行。

---

## 风险与待决项

| # | 事项 | 影响 | 处理 |
| --- | --- | --- | --- |
| R1 | `MultitouchSupport` 为私有框架，结构布局可能随系统变化 | 手势入口可能失效 | 运行时 `dlsym` 判空并降级到菜单栏 / 快捷键；macOS 12、13、14、15、26、27 各跑一次探针 |
| R2 | 输入监控是否必需尚未确定（评估 §11.3 T0） | 可能多一项权限 | T12 先做 T0 实测，再决定是否在引导中加该项 |
| R3 | 关闭系统四指手势会失去原有全屏切换 / 调度中心手势 | 产品代价 | 引导中明确说明；不静默改偏好；冲突时降级为显式提示 ；**被 T25 取代**：默认由 App 拦截系统四指手势，五指上滑代替调度中心 |
| R4 | 桌面枚举依赖系统私有信息，UUID 可能为空 | 桌面绑定不稳定 | 按编号 + 会话内标识绑定，不假设 UUID 永久稳定；系统重启与自动重排需回归 |
| R5 | 现有 `PreferencesView` 为标签页结构，D21 要求单页 | 设置入口整合方式未定 | 已定（2026-10-23）：在现有 `PreferencesView` 新增“九宫格”标签页，标签页内单页纵向分区，不改造整个设置窗口 |
| R6 | 现有 `OnboardingView` 已承担首启权限引导 | 可能与九宫格引导重复 | 已定（2026-10-23）：九宫格前置条件引导为独立窗口（`DesktopGridOnboardingView`），不并入首启流程 |
| R7 | `Control+N` 键位可能被用户修改、桌面编号需按按键时顺序计算 | 直达可能失败 | T15 读取真实键位与全局顺序，失败时回退相邻切换并提示 |
| R8 | 多显示器时每个显示器有独立 Spaces | 总览目前只取主显示器的普通桌面，副屏桌面不出现 | 阶段 3 明确按主显示器建模；T23 前按目标屏 `Display Identifier` 扩展并补提示 |
| R9 | 每桌面最多抓 3 个窗口缩略图，9 桌面最多 27 次请求 | 打开总览时截图队列可能偏慢 | 依赖 ThumbnailService 并发上限 6、缓存与 6s 刷新窗口；T22 真机测性能，必要时降到 1–2 个 |
| R10 | `gridEnabled=false` 时菜单入口仍可打开总览 | 主开关暂未成为唯一入口 | **已收口（2026-10-23）**：`StatusBarView` 菜单项按 `gridEnabled` 置灰；`GridOverviewPanel.show()` 在关闭时拒绝打开并记 `reason=grid_disabled`；监听停止时 `AppDelegate` 收起总览与 HUD。真机复验见 T24-B 第 13 项 |
