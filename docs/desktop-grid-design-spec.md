# Switchly 九宫格虚拟桌面设计说明

> 状态：设计定稿（2026-10-23），**工程尚未实施**。本文描述目标形态与移植约束，不声称任何源码已修改。
> 长期视觉规范仍以 [设计系统](design-system.md) 与 [界面工程约束](ui-guidelines.md) 为准；本文只补充九宫格专属的部分，冲突时按“项目文档 > 本文 > 设计过程草稿”的顺序裁决。
> 原型 `.taste-design/work/proto/v003.html` 是过程资料，**不会入库**；它只用于对照视觉与交互，图文不一致时以本文为准。
> 输入材料：`.taste-design/work/handoff/DESIGN.md`、`.taste-design/work/handoff/HANDOFF.md`、`.taste-design/work/tokens.css`、`.taste-design/work/assets/spec.md`、`.taste-design/work/qa/manual-checks.md`。

## 1. 范围与非目标

**范围**：在现有菜单栏工具内新增“九宫格虚拟桌面”（下称九宫格），提供桌面总览、手势切换 HUD、设置分区和前置条件引导四个界面，数据来自本机系统桌面与窗口，缩略图本地生成与缓存。

**非目标**（不在本期承诺，也不得写成已支持）：

- 不把系统 Spaces 改造成真正的二维桌面，不替换系统原生垂直手势与切换动画。
- 不接管、不拦截系统四指手势；不静默修改系统偏好。
- 不做窗口拖放与“移动并跟随”（后端未通过验收，见 [评估](desktop-grid-evaluation-2026-10-21.md) §10.5）。
- 不引入网络、遥测、账号或在线素材；不新增位图资产包。
- 不承诺 macOS 12–27 全版本私有接口兼容；只在有实测证据的版本上宣称可用。

## 2. 已确认决策（全部维持）

以下为用户已确认的决策编号，本期不推翻、不改写。编号含义取自 `.taste-design/record/decisions/`，结论沿用：

| 编号 | 结论 | 本文落点 |
| --- | --- | --- |
| D10-direction | 总览默认方向 **C**（全屏空间化 3×3 透视网格，中心格放大），方向 B（居中大面板）作为可选总览样式；背景改为**米白或纯白**，不使用紫蓝渐变 | §4、§5、§6 |
| D20-onboarding-home | 前置条件引导是**独立窗口**，不是设置页内的一个区块 | §3.4 |
| D21-settings-layout | 设置页采用**单页纵向分区**，不新增横向标签页 | §3.3 |
| D22-style-switch | 提供总览样式 **C / B 切换**，两种样式信息层级与元素顺序一致 | §3.1、§6 |
| D31-bench-thumb | 桌面缩略图按 **C 精细**：壁纸底、真实比例层叠窗口、可见标题栏，并与 Switchly 设计系统统一 | §9.1 |
| D32-bench-icon | 应用图标按 **C 精细**：18pt、22% 圆角、轻微渐变、内高光、通用线性符号，缺失退字母块 | §9.2 |
| D60-overview-hud | 总览与 HUD 四项细节全部保留：窗口数、目标方向箭头、HUD 键位提示、空桌面“这里很清静” | §3.1、§3.2 |
| D61-settings-guide | 设置与引导四项细节全部保留：已完成步骤折叠、6 个前置条件进度点、映射格应用图标、“无法检测”柔和文案 | §3.3、§3.4 |
| D90-review | 交付前复核的 26 项代定事项**全部维持**，不推翻 | 全文 |

“默认 C 精细样式”包含两个互相独立的 C：**布局 C**（D10，透视网格）与**资产精细度 C**（D31/D32）。二者不得混为一个设置项。

## 3. 四个界面

### 3.1 总览面板

| 项 | 规格 |
| --- | --- |
| 用途 | 一眼看清 9 个桌面的内容、当前所在与滑动目标 |
| 默认样式 | C：3×3 透视网格，`rotateX(9°)`、整体 `scale(0.88)`、中心格放大至约 2.1 列宽 |
| 可选样式 | B：居中玻璃大面板，`3 × 1fr`、格高约 176pt、面板最大宽约 900pt |
| 结构 | 顶部菜单栏条 → 状态胶囊（“桌面 5 → 9”或面板标题）→ 提示条（未创建 / 无权限 / 降级）→ 3×3 网格 → 页脚键位提示 |
| 单格内容 | 桌面编号（大号等宽数字）、桌面名、键位 chip（`⌃1`…`⌃9`）、状态 chip、缩略图、应用图标行（≤4 + “+N”）、窗口数（D60-A） |
| 状态编码 | 当前格：实线外环 + “当前”文字 chip；目标格：虚线外环 + “↘ 目标”chip（D60-B）；不单靠颜色 |
| 交互 | 方向键在九格间移动，Enter 切换，Esc 关闭；鼠标点击格子直达；Tab 遍历 9 格 |
| 保持不动 | 两种样式共享间距、圆角、玻璃语言、信息层级与元素顺序；只有几何与容器不同 |

### 3.2 手势切换 HUD

| 项 | 规格 |
| --- | --- |
| 载体 | 无边框浮动 `NSPanel`，`collectionBehavior` 含 `.canJoinAllSpaces`、`.fullScreenAuxiliary`，不抢焦点 |
| 结构 | 玻璃药丸 + 8 向方向环（当前方向高亮）+ “当前 → 目标”标题 + 方向副标题 + 3×3 迷你映射 |
| 文案 | 副标题同时给出手势与键盘两条路径，例如“四指向右下滑动 · 或按 ⌃9 直达”（D60-C） |
| 生命周期 | 手势阈值命中后出现（`panelDuration` 0.22s 淡入），切换完成后消失；系统切换期间保持可见 |
| 状态 | 见 §10；冷却与“切换中”期间不再触发新切换，但 HUD 仍显示当前目标 |

### 3.3 设置 → 九宫格

| 项 | 规格 |
| --- | --- |
| 结构 | 单页纵向分区（D21）：启用开关 → 前置条件状态（6 项 + 进度点，D61-B）→ 3×3 桌面映射（每格右上两个应用图标，D61-C）→ 手势参数（最少手指数、阈值、冷却、斜向偏置、方向反向）→ 总览样式 C/B → 背景米白/纯白 → 重置 |
| 现有偏好设置 | 现有 `PreferencesView` 使用 `PreferencesTab`（general / apps / permissions / shortcuts）。本分区以“九宫格”纵向段落进入单页结构，依据 D21；与现有标签页的整合方式见 §13 差异 2 |
| 状态标签 | 每个前置条件显示“已满足 / 未满足 / 无法自动检测”，文案柔和（D61-D） |
| 不做 | 不提供自由取色器；强调色来自系统 accent；不重复做系统“减少动态效果”的开关 |

### 3.4 前置条件引导窗口

| 项 | 规格 |
| --- | --- |
| 载体 | 独立 `NSWindow`（D20），复用现有 `OnboardingWindow` 的窗口生命周期与 `Motion.fadeInWindow` |
| 结构 | 标题/副标题 → 进度条（6 项）→ 步骤列表 → 单项操作按钮 → 页脚“稍后 / 开始使用” |
| 步骤 | ① 辅助功能 ② 屏幕录制 ③ 至少两个桌面 ④ 关闭系统四指横扫 ⑤ 关闭系统四指竖扫 ⑥ 手势与快捷键可用性自检 |
| 折叠 | 已满足的步骤折成一行（D61-A），把注意力留给未完成项 |
| 无法检测项 | 明确写“系统不让应用查看这一项，请你确认后点‘我已完成’”，不伪装成检测通过 |
| 关闭 | 关闭不等于全部满足；未满足时总览与设置显示对应提示条 |

## 4. 布局与几何

- 面板尺寸与位置一律由目标屏幕 `visibleFrame` 决定，覆盖副屏、混合缩放、Dock 方位与全屏空间。
- 方向 C：网格列宽比 `1fr : 2.1fr : 1fr`，行高比 `.85fr : 1.6fr : .85fr`，整体 `scale(0.88)`、origin 约 `50% 45%`；1440×900 与 760 高两种窗口下三行不出屏。`rotation3DEffect` 的透视值需实机调，不能直接抄网页 `perspective`。
- 方向 B：`3 × 1fr`，格高约 176pt，面板最大宽约 900pt，高度随可见区收缩。
- 单格内边距 `Spacing.lg`，格间距 `Spacing.xl`（C）/ `Spacing.md`（B），圆角 `Radius.panel`。
- 长桌面名单行截断；窄格（≤480pt 宽）隐藏应用图标行；缩略图内窗口名在容器 ≤150pt 时隐藏。
- 缩略图占满格子内容区，状态 chip 固定在格顶栏，不遮挡缩略图。

## 5. 背景与外观

| 背景轴 | 浅色 | 深色 |
| --- | --- | --- |
| 米白（默认，`cream`） | 三色暖灰渐变 `#FBF9F3 → #F5F2EA → #EEE9DC`，叠加左上柔光 | 不适用，统一石墨 |
| 纯白（`white`） | `#FFFFFF`，无渐变 | 不适用，统一石墨 |
| 深色（固定） | — | 中性石墨 `#34363D → #2A2C31 → #1B1C20` |

- 背景只影响总览面板的壁纸底；HUD、设置与引导沿用当前材质与密度。
- 深色强调色 `#4AA0F5`，浅色强调色 `#1760C4`；均以系统 accent 为源，不写死品牌色。
- 玻璃面板必须同时检查 `NSPanel` 背景与 SwiftUI 内容层：窗口透明而内容不透明属于缺陷。
- 禁止紫蓝整体底（D10）；缩略图壁纸色晕也不得用紫蓝。

## 6. 设置轴

| 轴 | 取值 | 默认 | 生效范围 | 原生落点 |
| --- | --- | --- | --- | --- |
| 总览样式 `style` | `c` 透视网格 / `b` 居中面板 | `c` | 仅总览 | `AppSettings.gridStyle`（新增） |
| 背景 `bg` | `cream` 米白 / `white` 纯白 | `cream` | 仅总览，且仅浅色生效 | `AppSettings.gridBackground`（新增） |
| 明暗 `mode` | `light` / `dark` / `system` | `system` | 全部界面 | **复用** `AppSettings.theme`（`AppTheme`） |
| 减少动态 `rm` | `0` 标准 / `1` 减少 | `0` | 全部界面 | **复用** `MotionTokens.reduceMotion`（系统偏好），不新增 app 开关，见 §13 差异 3 |

- 新增字段必须同时更新默认值、`CodingKeys`、`init(from:)` 的 `decodeIfPresent` 回退、设置 UI 与运行态消费方。
- 未知枚举值回退默认值并记录日志，不抛错、不清空旧设置。
- 手势参数（最少手指数 4、阈值 12mm、丢指容忍 80ms、冷却 350ms、斜向偏置 0–5°）属于实现参数，默认值写在本节，是否暴露为滑杆由 T17 决定。

## 7. 令牌映射

原型数值在 `tokens.css`；下表只保留需要落到 Swift 的部分。**网页 px 不等于 pt**，字号与几何按系统文本样式与 `visibleFrame` 重新取值，下表数值是目标方向，不是换算结果。
标记口径：§7.1 各行均为**复用**（符号已在源码中存在）；§7.2 各行均为**新增（待实现）**，其中标注“不移植”的一行保留设计值但不进入工程。

### 7.1 可直接复用（现有符号）

| 设计令牌 | 值 | Swift 落点 |
| --- | --- | --- |
| `--sp-xs / sm / md / lg / xl` | 4 / 8 / 12 / 16 / 24 | `DesignTokens.Spacing.xs / .sm / .md / .lg / .xl` |
| `--r-panel` | 28 | `DesignTokens.Radius.panel`（= `GlassPanelCorner.radius`） |
| `--r-card` | 16 | `DesignTokens.Radius.card` |
| `--r-thumb` | 10 | `DesignTokens.Radius.thumbnail` |
| `--r-ctl` | 12 | `DesignTokens.Radius.control` |
| `--r-pill` | 999 | `DesignTokens.Radius.pill` |
| `--r-chip` | 6 | `DesignTokens.Radius.chip` |
| `--hair` | 0.5 | `DesignTokens.hairline` |
| `--t-micro` | 0.12 | `MotionTokens.microDuration` |
| `--t-panel` | 0.22 | `MotionTokens.panelDuration` |
| `--t-morph` | 0.28 | `MotionTokens.morphDuration` |
| `--t-ws` | 0.34 | `MotionTokens.workspaceSwitchDuration` |
| 目标格脉冲 0.28s | 0.28 | `MotionTokens.morphDuration`（不新增） |
| `--ink` 浅色 | `#1A1C21` | `Color.crystalGraphite` |
| `--ink2 / --ink3` | 次要/三级文字 | `Color.crystalSecondary(on:)` + 现有语义色，不在 View 里降透明度 |
| `--panel` / `--card` 底 | 半透明白/黑 | `.panelGlass(isActive:opacity:cornerRadius:tintColor:material:)`、`.cardSurface(fill:cornerRadius:material:isSelected:)` |
| `--sheen` / `--rimA` / `--rimB` | 0.55 / 0.95 / 0.60 | `.crystalSpecularRim(cornerRadius:material:isHighlighted:lineWidth:)` + `CrystalMaterial.topSheenOpacity`、`.rimTopOpacity`（`CrystalMaterial.Range` 限幅） |
| `--accent` | sRGB(60,150,240) | `Color.accentColor`（跟随系统）；`CrystalMaterial.legacyDefault.tintColor` |
| 卡片基底 | 系统控制背景 | `Color.crystalSurfaceBase`、`CrystalCardFill.opacity(_:)` |
| 柔光/唇边基底 | 深浅自适应 | `Color.crystalSheenTop`、`Color.crystalRimBase`、`Color.crystalPanelHairline`、`Color.crystalChipBase`、`Color.appearanceAware(dark:light:)` |
| 缩略图底色压暗 | 黑 0.16 / 0–0.60 | `ThumbnailBackdrop.legacyDefault`、`ThumbnailBackdrop.Range.opacity` |
| 面板出现/消失 | 0.22s | `Motion.fadePanel`、`MotionTokens.panelSpring` |
| 卡片 hover 抬升 | 0.12s | `MotionTokens.microDuration`、`MotionTokens.microSpring` |
| 滑块实时预览 | — | `MotionTokens.interactiveSpring` |
| 减少动态效果判定 | — | `MotionTokens.reduceMotion`、`MotionTokens.animated(_:)` |
| 明暗轴 | light/dark/system | `AppTheme`、`ThemeApplier` |

### 7.2 新增（待实现）

| 设计令牌 | 值 | 建议落点 | 说明 |
| --- | --- | --- | --- |
| `--tilt` | 9° | `DesignTokens.Grid.tilt` | 仅方向 C |
| 网格比例 | `1:2.1:1 × .85:1.6:.85` | `DesignTokens.Grid.columnFractions` / `.rowFractions` | 仅方向 C |
| 总览缩放 | 0.88 | `DesignTokens.Grid.overviewScale` | 防第三行出屏 |
| 目标格位移 | `translateZ 24`、`scale 1.02` | `DesignTokens.Grid.targetLift` / `.targetScale` | 与虚线环并用 |
| hover 抬升 | 3pt | `DesignTokens.Grid.hoverLift` | 单格 |
| 样式 B 几何 | 176pt 高、900pt 最大宽 | `DesignTokens.Grid.styleBCellHeight` / `.styleBMaxWidth` | 见 §13 差异 4 |
| 字号层级 | 22 / 14 / 12 / 44 | `DesignTokens.Typography.gridTitle` / `.gridCard` / `.gridMeta` / `.gridNumber` | 当前 `DesignTokens` 无排版常量 |
| 米白/纯白/石墨底 | 见 §5 | `DesignTokens.Grid.Wall.cream` / `.white` / `.graphite` | 渐变令牌 |
| 应用色块 8 色 | `#1D5FD1`…`#C0243F` | `DesignTokens.Grid.AppPalette` | 字母块降级，白字对比 ≥4.5:1 |
| 状态色 | `#1A7F45` / `#9A5A00` / `#B3261E` | `DesignTokens.Grid.Status.ok` / `.warn` / `.bad` | 语义标签 |
| 缩略图内窗口 | `--win-bg/edge/dot/ink/line` | `DesignTokens.Grid.Window.*` | 随明暗切换 |
| 轨迹流动周期 | 2.4s | `MotionTokens.gridTraceDuration` | 唯一新增动效时长 |
| 面板模糊半径 | 44px / 18px | **不移植** | 原生由 `NSVisualEffectView` / `CrystalMaterial` 公式决定，不暴露数值 |
| 背景轴模型 | cream/white | `AppSettings.gridBackground` + 新枚举 `GridBackground` | 不新增存储键 |
| 样式轴模型 | c/b | `AppSettings.gridStyle` + 新枚举 `GridStyle` | 不新增存储键 |
| 启用开关 | Bool | `AppSettings.gridEnabled` | 默认关闭，避免升级后自启 |

## 8. 动效与减少动态效果

| 什么在动 | 怎么动 | 时长 | 覆盖 |
| --- | --- | --- | --- |
| 目标格高亮切换 | 亮度 1.25 → 1 的单次脉冲 | `MotionTokens.morphDuration`（0.28s） | 单格 |
| 格子 hover | 抬升 3pt | `MotionTokens.microDuration`（0.12s） | 单格 |
| HUD 出现/消失 | 淡入 + 轻微缩放 | `MotionTokens.panelDuration`（0.22s） | HUD |
| 方向轨迹（仅 C） | 虚线相位流动 | `MotionTokens.gridTraceDuration`（2.4s 循环，仅手势期间） | 当前格 → 目标格路径 |
| 面板/窗口首次出现 | 淡入 | `MotionTokens.panelDuration` | 总览、引导 |

- 所有 SwiftUI 动画必须走 `MotionTokens.animated(_:)`；AppKit 面板用 `Motion.fadePanel` / `Motion.movePanel` / `Motion.fadeInWindow`。
- 开启系统“减少动态效果”时：脉冲改为即时换色、轨迹改为静态线、HUD 与面板即时出现；焦点与选中状态仍须可识别。
- 不可见时停止：面板关闭或切到后台时，取消轨迹动画与截图刷新，不保留常驻 `TimelineView`。
- 不做重复动画的“氛围层”；每格不新建 `NSVisualEffectView`。

## 9. 资产规范

### 9.1 桌面缩略图（C 精细，D31）

| 项 | 规格 |
| --- | --- |
| 结构 | 壁纸三色低饱和底（暖/绿/灰，9 套各异）+ 顶部约 7% 菜单栏示意 + 2–3 个按真实宽高比（1.35–1.55）前后层叠的窗口块 |
| 窗口块 | 标题条约 11pt（应用色 20% 混窗口底）+ 三点（前台红黄绿、后台灰）+ 应用名（容器 ≤150pt 隐藏）+ 按应用类型的内容骨架 |
| 几何 | 窗口圆角 7、0.5 细线；投影两档（后台 `0 4 10 黑 20%`，前台 `0 8 18 黑 32%`） |
| 安全区 | 窗口块限制在容器 6%–94%；状态 chip 与编号不入缩略图区 |
| 降级 | 无屏幕录制权限 → 简化块（应用色块 + 标题条 + 应用名）+ 顶部提示条；图标与标题照常显示 |
| 加载 | 保留占位，不闪白；占位替换用 `MotionTokens.thumbnailTransition` |
| 可访问性 | 作为图片朗读，名称含“预览（示意）”，不冒充真实内容 |
| 禁止 | 纯色平涂、无标题条/投影、窗口越界、紫蓝整体底、用颜色单独表达状态 |

真实运行时优先显示本地小尺寸窗口截图；缓存边界不变（按原始截图时间最多复用 24 小时，磁盘总量 ≤64MB，不保存放大原图）。

### 9.2 应用图标（C 精细，D32）

| 项 | 规格 |
| --- | --- |
| 尺寸 | 1:1，行内 18pt；间距 `Spacing.xs`；窄格整行隐藏 |
| 外观 | 圆角 22%、应用色上到下轻微渐变（底部加深约 16%）、顶部内高光、0.5 细线、极轻投影 |
| 符号 | 居中通用线性符号（约 11pt、白色、描边 2.2、圆角端点）：邮件/气泡/罗盘/便签/形状/图片/代码/终端/视频/音乐/文件夹；**不使用第三方品牌标志** |
| 降级 | 取不到符号 → 首字母块（10pt 粗体白字）；应用名为空 → “?”；取不到颜色 → 中性灰 |
| 对比 | 白符号与底色 ≥4.5:1；沿用手册 8 色 |
| 行内折叠 | 最多 4 个，第 5 个起折叠为“+N”（次要色） |
| 可访问性 | 每个图标有可朗读名称 = 应用名 |

## 10. 状态清单

| 状态 | 触发 | 总览 | HUD | 设置/引导 | 禁止 |
| --- | --- | --- | --- | --- | --- |
| 正常 | 桌面存在且权限齐全 | 显示缩略图与图标行 | 方向环 + 目标标题 | 6 项全满足 | — |
| 未创建桌面 | 目标格无系统桌面 | 整格虚线 + 大号编号 + 引导文案 | “桌面 N 未创建”，不触发切换 | 映射格标“未创建” | 画窗口块 |
| 无辅助功能权限 | `AXIsProcessTrusted()` 为假 | 提示条 + 窗口数据降级 | 仅显示桌面编号与名称 | 前置条件第 1 项未满足 | 显示空网格 |
| 无屏幕录制权限 | `CGPreflightScreenCaptureAccess()` 为假 | 简化块 + 提示条；图标与标题保留 | 不显示缩略图 | 前置条件第 2 项未满足 | 空白或误报 |
| 切换中 | 已发出切换指令，未确认到达 | 目标格高亮保持 | 保持可见，显示“切换中” | 手势参数只读 | 重复触发 |
| 边缘 | 方向指向不存在的桌面 | 不做目标高亮 | 方向环对应向置灰，不循环 | — | 回绕到另一端 |
| 冷却 | 触发后 350ms 内 | — | 保持当前目标，不再响应 | — | 叠加新切换 |
| 空桌面 | 桌面存在但没有窗口 | “这里很清静”（D60-D） | “无窗口” | 映射格显示 0 窗口 | 显示空白缩略图 |
| 加载中 | 缩略图未就绪 | 占位骨架，不闪白 | — | — | 抖动布局 |
| 手势不可用 | 私有框架不可用或触点缺失 | 提示“手势不可用，可用 ⌃1–9” | 不出现 | 前置条件第 6 项未满足 | 静默失败 |

## 11. 可访问性与双语

- 每个格子可朗读“桌面 N、名称、当前/目标”；9 格 Tab 顺序与视觉顺序一致，焦点环可见。
- 当前/目标同时使用轮廓差异 + 文字 chip，不以颜色单独编码；增强对比度下文字仍可读。
- HUD 不抢焦点、不打断 VoiceOver 朗读；出现与消失不发出多余播报。
- 面板与窗口提供 Esc 关闭、方向键移动、Enter 确认、⌃1–9 直达。
- 所有新增用户文案同时维护 `Resources/en.lproj/Localizable.strings` 与 `Resources/zh-Hans.lproj/Localizable.strings`；复用 `AppLanguage` 的取词方式，不在 View 内拼字符串。
- 错误文案说明用户可采取的动作；AX 返回码、私有框架错误等细节只进 `AppLogger`。
- 中文与英文都检查截断：长桌面名、长应用名、“无法自动检测”长句。

## 12. 原生移植要点

| 网页能力 | 原生做法 |
| --- | --- |
| `backdrop-filter` | 复用 `.panelGlass` / `.cardSurface` / `.crystalSpecularRim`；不新建平行模糊实现 |
| CSS 渐变 | `LinearGradient` / `RadialGradient`；壁纸色取自令牌，不内联 Hex |
| `rotateX` + `perspective` | `rotation3DEffect` + `perspective`，按 `visibleFrame` 调整，第三行不得出屏 |
| 容器查询 | `GeometryReader` + 尺寸分支；原生断点按 pt 与 `visibleFrame` 定，不抄网页 375/768/1440 |
| `stroke-dashoffset` | `Path.trim` + `TimelineView`，或 `CAShapeLayer.lineDashPhase`；不可见时停止 |
| `prefers-reduced-motion` | 复用 `MotionTokens.reduceMotion` 与 `MotionTokens.animated(_:)` |
| `:focus-visible` | `@FocusState` + AppKit `firstResponder` 焦点环 |
| SVG 符号 | `SF Symbols` 通用符号或 `Path` 绘制；不用品牌图标 |

**平台与权限约束**：

- 手势：四指原始触点只能经 `MultitouchSupport` 私有框架读取（`MTDeviceCreateList`、`MTRegisterContactFrameCallback`、`MTDeviceStart` 等），运行时 `dlsym` 判空，禁止链接期依赖；macOS 12–27 只在 27.0.1 实测，其余版本需逐版本跑探针。私有 API 使 Mac App Store 分发不可行。
- 系统手势冲突：无法拦截系统四指手势，只能**引导用户关闭**“在全屏 App 之间轻扫”和“调度中心/应用 Exposé”，检测到冲突时提示；不得静默修改系统偏好。
- 切换：目标桌面有窗口时优先激活该窗口所属应用（`NSRunningApplication.activate`，复用 `WindowSwitchService.switchToApplication(pid:)`）；空桌面或需要确定编号时合成系统 **Control+N**，并按按键时的全局桌面顺序计算 N。不得使用 bridged `SetCurrentSpace`。
- 成功判定：以“公开通知 + 目标窗口在屏 + 前台应用”闭环确认，不以 current getter 命中代替。
- 权限：辅助功能与屏幕录制分别判断与提示；缺失时保留图标与标题；不因“修权限”开启 App Sandbox 或增加 entitlements。
- 兼容：最低 macOS 12；新系统 API 需可用性检查与降级；构建需 Xcode 26+。
- 线程：UI 状态与面板操作在主线程；触点回调不得直接改可观察状态，需切主队列；停止时反注册回调并 `MTDeviceStop`。

## 13. 与设计稿的已知差异

| # | 设计稿 / 原型 | 本文处理 |
| --- | --- | --- |
| 1 | HANDOFF §2 把 `Views/OnboardingView.swift` 写成“新引导窗口” | 该文件已存在（首启权限引导）。九宫格前置条件引导应扩展它或新增独立视图，不得再创建一个同名文件 |
| 2 | D21 要求“单页纵向分区”，现有 `PreferencesView` 是四个标签页 | 九宫格分区按单页纵向实现；是否改造整个设置窗口为单页需另行确认，本文不擅自改既有标签页结构 |
| 3 | 设置轴含独立 `rm`（0/1） | 原生复用系统“减少动态效果”偏好（`MotionTokens.reduceMotion`），不新增 app 内开关，避免与系统设置重复 |
| 4 | `tokens.css` 里样式 B 的最大宽为 940px，HANDOFF 与资产规范写 900 | 以 900pt 为准；940 视为原型遗留值，实施时不采用 |
| 5 | `tokens.css` 的 `[data-style="b"]` 引用了未定义的 `--radius-panel` / `--radius-card` / `--space-md` | 原型变量名笔误，实际应引用 `--r-*` / `--sp-*`；不影响原生映射 |
| 6 | HANDOFF 称 HUD 复用“系统 Control+N 切换（WindowSwitchService）” | 现有 `WindowSwitchService` 只做应用激活与窗口聚焦，没有桌面切换能力；Control+N 需新增合成事件与导航服务 |
| 7 | DESIGN §8.3 把“桌面枚举”指向 `AccessibilityService`、把 ⌃1–9 指向 `ShortcutService` | 二者目前都没有桌面能力；桌面枚举与 ⌃1–9 注册均需新增实现，`ShortcutService` 可复用其 `HotKey` 注册骨架 |

## 14. 验收边界

- 本文是设计契约，不是实现证据。原型截图、无头浏览器结果不能替代原生材质、AX 枚举、真实桌面切换与多显示器验证。
- 实施验收以 `make build`、`make test-unit`、`./verify.sh` 为门禁，并按 [manual-checks](../.taste-design/work/qa/manual-checks.md) 在目标 Mac 上逐项人工确认。
- 未执行或无法执行的项目必须写明原因，不得报告为通过。
- 原生行为证据、截图与性能数据随实施 PR 提交；过程截图放系统临时目录，不入库。
