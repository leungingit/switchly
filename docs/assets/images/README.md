# README 图片资产

这些文件供仓库根目录的中英文 README 引用，使用相对路径，可随仓库直接分发。

| 文件 | 用途与来源 |
| --- | --- |
| `hero-en.svg` / `hero-zh.svg` | 本次 README 制作的矢量功能示意，使用虚构的编辑器、浏览器、文件窗口内容。非产品截图，不承诺精确布局。 |
| `workflow-en.svg` / `workflow-zh.svg` | 本次制作的三条功能路径示意：预览面板、Dock 悬停、工作区。非产品截图。 |
| `desktop-grid-en.svg` / `desktop-grid-zh.svg` | 九宫格桌面的矢量示意：3×3 总览（含当前桌面与滑动目标）及三指、四指、五指手势说明，使用虚构内容。非产品截图。 |
| `preferences-source-render.png` | 来自设计评审阶段的原生 SwiftUI 源码渲染，已独立保存。证据边界见 [界面工程约束](../../product/ui-guidelines.md)；不是桌面实拍，不保证与后续源码逐像素一致。 |
| `../../Website/images/shots/*.png` | 官网与 README 使用的 Dock 预览、工作区、九宫格、音乐插件截图：真实面板配合虚构演示内容在桌面合成后截取，保存在 `Website/images/shots/`。 |

新增官网共用资产：

| 文件（位于 `Website/images/shots/`） | 来源与边界 |
| --- | --- |
| `activity.png` | 2026-11-17 使用 `SwitchlyActivityProbe --render-panel --opaque` 渲染正式原生视图；只用合成区间与样例图片，不读取真实活动库，不启动采集。图内日期是样例渲染日期。 |
| `capture-flow.svg` | 窗口截图流程的手绘矢量示意，展示入口、冻结框选和结果操作，非截图，不作为系统行为证据。 |
| `preview-flow.svg` | 独立预览的矢量流程示意，展示合成场景、正式运行时和输出产物，非运行截图，不代表 npm 发布。 |

上述三图由官网与两份 README 共用；文字说明保留默认关闭、权限和验证范围。SVG 无外部资源或脚本。

示意图使用独立文案和 SVG 基础图形，无第三方图片、字体或在线渲染依赖。当前源码与发布版本可能不同，README 已明确标注。后续取得有代表性的真实截图或录屏时，应优先替换主图并同步两种语言的说明；截图须使用可公开的演示内容。
