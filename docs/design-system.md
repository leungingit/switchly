# Switchly 设计系统

本文是原生 macOS 界面的长期视觉规范，与 [界面工程约束](ui-guidelines.md) 配套使用。适用于预览面板、Dock 预览、工作区切换栏、偏好设置、工作区管理和使用统计。数值以链接的共享实现为准；变更实现时同步更新本文。

## 视觉方向与已确认意图

采用 visionOS 参考的空间光学水晶语言：上亮下透的柔光、左上至右下的镜面唇边、大曲率连续圆角，以及清晰的内容层级。材质透出背后桌面的色相，不把示例壁纸的蓝紫色当作产品固定配色。用户可以调整材质和布局。

共享视觉语言不等于共享布局。用户在全界面评审中明确要求：不能把预览主面板的舞台、侧栏或网格套到 Dock、偏好设置或工作区管理。各界面保留自己的业务结构。

| 界面 | 结构职责 |
| --- | --- |
| 主预览面板 | 搜索、窗口缩略图网格；舞台布局可增加悬浮侧栏和焦点条。 |
| Dock 预览 | 面向单个应用的窗口预览条，贴靠对应 Dock 图标。 |
| 工作区切换栏 | 切换工作区、展示该组应用和窗口，宽度随内容及屏幕边界约束。 |
| 偏好设置 | 分类设置、表单、分段选择器、滑块和材质示意。 |
| 工作区管理 | 工作区列表和编辑区域，保持编辑任务的信息层级。 |
| 使用统计 | 图表、次数和效率估算明细，优先保证数据可读。 |

## 共享实现入口

| 关注点 | 唯一入口 |
| --- | --- |
| 间距、圆角、细线 | [DesignTokens.swift](../Utilities/DesignTokens.swift) |
| 动效、过渡、减少动态效果 | [MotionTokens.swift](../Utilities/MotionTokens.swift) |
| 玻璃、柔光、镜面边、语义颜色 | [GlassEffect.swift](../Utilities/GlassEffect.swift) |
| 外观模式应用 | [ThemeApplier.swift](../Utilities/ThemeApplier.swift) |
| 材质参数、布局、旧设置迁移 | [AppSettings.swift](../Models/AppSettings.swift) |
| 持久化和运行态通知 | [SettingsService.swift](../Services/SettingsService.swift) |

## 尺度与排印

以下为当前源码值，单位为 pt。不要从网页原型的 px 或响应式断点推导原生窗口尺寸。

| 令牌 | 当前值 |
| --- | --- |
| `Spacing.xs / sm / md / lg / xl` | 4 / 8 / 12 / 16 / 24 |
| `Radius.panel` | 28，引用 `GlassPanelCorner.radius` |
| `Radius.card / thumbnail / control` | 16 / 10 / 12 |
| `Radius.pill / chip` | 999 / 6 |
| `hairline` | 0.5；选中镜面边由共享材质实现处理 |

使用系统字体，不引入第三方字体。设计层级以面板标题约 22pt、卡片标题约 14pt、元数据约 12pt 为参考，具体控件优先采用适合其用途的系统文本样式。数字对齐用 `.monospacedDigit()`，需要时为快捷键选用等宽字体。缩略图和图表保持锐利，不叠加装饰性模糊。

## 当前材质设置与兼容

当前模型是 `CrystalMaterial`，不再提供 Ice / Quartz / Frameless 固定主题枚举。不要重建平行预设系统。

| 字段 | 默认值 | 设置范围 / 含义 |
| --- | --- | --- |
| `glassStyle` | `.frosted` | 透明 / 磨砂 / 关闭；旧数据默认为磨砂，不自动选择新的默认视觉。 |
| `sharedDensity` | `nil` | 0…1；nil 保留旧面板与普通窗口各自的数值，用户拖动后统一。 |
| `tintColor` | sRGB (60, 150, 240) / 255 | 所有表面共用的 sRGB 染色。 |
| `panelTintCap` | 1.0 | 0…1，染色强度；零不染色，与密度、柔光独立。 |
| `cardOpacity` | 0.10 | 0…0.30，共享卡片分隔底色；零移除静止卡片填充。 |
| `topSheenOpacity` | 0.18 | 0…0.40，磨砂模式的顶部柔光。 |
| `rimTopOpacity` | 0.57 | 0…1，磨砂模式的边缘高光。 |
| `panelMaterial` | `.glass` | 浮动面板结构：玻璃面板 / 无面板，归入布局。 |
| `baseTone` | `.automatic` | 只保留存储兼容，不再覆盖渲染或出现在界面中。 |

外观选项集中于独立的「外观」标签页，基础项为主题、材质、密度、染色；卡片分隔、磨砂柔光与边缘、缩略图衬底位于高级折叠区。语言保留在「通用 → 系统」。

透明模式在 macOS 26+ 使用公开 `NSGlassEffectView(style: .clear)`，实际 SwiftUI 内容装入 `contentView`；复用现有 hosting view 更新，避免密度拖动时重建控件。旧系统降级为系统材质。磨砂模式使用 `NSVisualEffectView(.popover)`；关闭玻璃使用主题相关的实色背景。

密度不是模糊半径：透明模式控制额外中性阅读层（0 保留原生透光与折射），磨砂模式直接控制背景材质 alpha（0 移除该背景层，无 30% 下限）。染色与高级高光各自独立，密度为零不会暗中清除它们。文字不随玻璃密度淡化。

所有表面共用 `GlassAppearance` 的染色、密度与柔光系数。`backgroundBlurOpacity` 与 `preferencesGlassOpacity` 保留旧键；`sharedDensity == nil` 时分别读取，设置页提示旧差异。用户调节共享滑块时同时写入共享值和两个旧字段。保留旧数值不等于保留旧版错误的系数映射。旧 `enableBackgroundBlur == false` 仍保留浮动面板的实色降级，重新选择材质后同步开关。

无面板只作用于浮动布局；玻璃关闭、密度零、无面板各有不同语义。透明模式使用系统光泽，卡片不再重复画整面光泽；磨砂光泽为零时不得留下固定灰色渐变或描边。

旧 `crystalThemePreset` 只用于解码迁移：`ice` 和未知值回退旧默认，`quartz` 展开暖色参数，`frameless` 展开中性色及 `.clear`。新增字段保留旧数据解码，参数限制复用 `CrystalMaterial.Range` 和现有 `clamped()` 消费路径。

## 材质与颜色层次

- 面板负责系统模糊与桌面透射。卡片复用面板底层，只叠半透明语义底、上亮下透柔光及镜面边；不为每张卡片创建 `NSVisualEffectView`。
- 复用 `.panelGlass()`、`.cardSurface()`、`.crystalSpecularRim()` 和普通窗口材质封装。连续圆角与内描边保持边界完整，装饰不能侵占内容安全区。
- 强调色用 `Color.accentColor`；主文字和底色优先系统语义色。次要文字使用跟随同一主题的语义墨色；`crystalSecondary(on:)` 不再强制深色，也不声称采样了实际壁纸亮度。
- 共享颜色按正在绘制的视图的 `effectiveAppearance` 解析。不要在构造时用应用级外观快照替代动态颜色；离屏或窗口独立主题可能与应用外观不同。
- 普通控件复用现有背景而不创建嵌套模糊；透明面板通过 AppKit 原生玻璃容器实现，不依赖 SwiftUI `View.glassEffect`。所有新 API 保留 macOS 12 降级。

## 布局与预览交互

当前 `PreviewPanelStyle` 只有 `stage` 与 `classicGrid`，默认 `classicGrid`。`stage` 包含悬浮侧栏和焦点条，并使用不同的卡片几何及列数计算。布局选项必须产生真实结构差异；历史 `pillMatrix`、`framelessTiles` 不应作为未实现的选项重新出现。

布局与交互模式是独立维度。`PreviewInteractionMode` 当前为 `highlightOnly` 与 `windowReplica`。旧 `heroPane` / `heroPaneFullScreen` 解码为窗口副本，不在产品文档中宣传已退役模式。

## 动效

| 当前令牌 | 秒 |
| --- | --- |
| `microDuration` | 0.12 |
| `panelDuration` | 0.22 |
| `morphDuration` | 0.28 |
| `workspaceSwitchDuration` | 0.34 |
| `contentSwapDuration` | 0.15 |
| `stateDuration` | 0.25 |
| `staggerStep / maxStagger` | 0.02 / 0.15 |

SwiftUI 动效经 `MotionTokens.animated()`，AppKit 面板使用 `Motion` 帮助方法。开启系统减少动态效果时以即时状态切换替代移动、缩放和淡入；焦点、选中与操作结果仍须可识别。优先共享弹簧和过渡，不在各视图自创时长。

## 设计过程归档结论与差异

本规范于 2026-10-20 从临时设计交付稿、用户决策与源码核对后整理。原型仅用于说明方向，不作为运行证据。为避免清理过程资料后丢失用户意图，保留以下差异：

| 历史确认或草稿 | 当前实现与处理 |
| --- | --- |
| 用户选择 V4 空间侧栏和主焦舞台作为视觉主方向，并要求主题 / 布局可切换。 | 当前支持舞台和经典网格，默认是经典网格。视觉主方向不等同于当前默认设置；未来改变默认需明确说明。 |
| 用户排印调参记录中的卡片圆角为 20px，旧交付表写成 16pt。 | 当前令牌为 16pt。原型单位和源码值不一致，此次只记录差异，不静默调整界面。面板圆角 28 与标题 22 / 卡片标题 14 的方向保留。 |
| 网页调色记录含冷白染色、0.14 面板透明度和 42px blur。 | 属于网页原型参数，不能直接映射为当前 AppKit 材质、wash 或系统模糊半径。 |
| 旧交付稿介绍三预设 × 四布局，后续 QA 缩至三预设 × 两布局。 | 当前进一步采用可调材质参数 × 两布局。旧预设仅保留迁移语义。 |
| 旧稿描述 macOS 26 原生 Liquid Glass，并列出固定对比度测量结果。 | 当前不宣称该 API 分支；旧测量依赖当时参数与离屏背景，不作为当前所有配置的对比度保证。 |

本轮整理没有重新执行视觉验收。当前回归步骤、证据边界与未验证场景见 [界面工程约束](ui-guidelines.md)。
