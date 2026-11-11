# Switchly 文档索引

`docs/` 是仓库文档的唯一入口。根目录只保留 GitHub 社区健康文件（README、CONTRIBUTING、SECURITY、PRIVACY_POLICY、CODE_OF_CONDUCT、CHANGELOG、LICENSE）与构建入口（Makefile、project.yml、mise.toml、build.sh、verify.sh）。

新文档按下表归档，不再直接堆在 `docs/` 顶层。

| 目录 | 放什么 | 不放什么 |
| --- | --- | --- |
| [product/](product/) | 产品形态、交互设计、设计系统与界面工程约束 | 实施进度、验收记录 |
| [engineering/](engineering/) | 工程约束、性能与资源记录、发布流程 | 产品构想 |
| [plugins/](plugins/) | 插件契约、API 参考、生态方案、预览工具链 | 宿主通用界面规范 |
| [research/](research/) | 调研底稿、实验夹具与原始数据 | 结论性规范 |
| [reviews/](reviews/) | 特定改造的实现与验证记录 | 目标方案 |
| [assets/](assets/) | 文档引用的图片与示意图 | 构建期资源（放 `Resources/`） |
| [plan/](plan/) | 本机过程草稿 | 需要长期维护的结论（该目录被 Git 忽略） |

命名沿用英文小写连字符；时间相关的评估、复盘用 `-YYYY-MM-DD` 后缀，过程草稿用 `YYYY-MM-DD-` 前缀。

## 产品与界面

| 文档 | 内容 |
| --- | --- |
| [design-system.md](product/design-system.md) | 原生 macOS 界面的长期视觉规范，数值以共享实现为准 |
| [ui-guidelines.md](product/ui-guidelines.md) | SwiftUI / AppKit 的实现与验收约束 |
| [desktop-grid-research-and-spec.md](product/desktop-grid-research-and-spec.md) | 九宫格虚拟桌面：场景调研、性能判断与交互方案 |
| [desktop-grid-feasibility-2026-10-20.md](product/desktop-grid-feasibility-2026-10-20.md) | 第一轮可行性研究（只读探测，未实现功能） |
| [desktop-grid-evaluation-2026-10-21.md](product/desktop-grid-evaluation-2026-10-21.md) | 第二轮评估与立项判断 |
| [desktop-grid-design-spec.md](product/desktop-grid-design-spec.md) | 设计定稿（工程尚未实施） |
| [desktop-grid-tasks.md](product/desktop-grid-tasks.md) | 九宫格开发任务台账 |

## 工程与性能

| 文档 | 内容 |
| --- | --- |
| [RELEASING.md](engineering/RELEASING.md) | 版本号规则与发布流程（版本真源是 `Resources/Info.plist`） |
| [performance-review-2026-10-20.md](engineering/performance-review-2026-10-20.md) | 性能检查与优化记录 |
| [idle-performance.md](engineering/idle-performance.md) | 空闲截图开销排查（D01 已被 D02 部分取代） |
| [thumbnail-cache.md](engineering/thumbnail-cache.md) | 缩略图跨次启动复用的目标、边界与生命周期 |

## 插件生态

| 文档 | 内容 |
| --- | --- |
| [plugin-api-reference.md](plugins/plugin-api-reference.md) | 宿主插件 API 参考；机器可读清单在 `Plugins/api/` |
| [plugin-api-roadmap.md](plugins/plugin-api-roadmap.md) | API / SDK 能力开放路线 |
| [plugin-ecosystem-plan.md](plugins/plugin-ecosystem-plan.md) | 插件外置化、管理机制与 API 标准化方案 |
| [plugin-externalization-progress.md](plugins/plugin-externalization-progress.md) | 外迁实施台账与已完成范围 |
| [dock-preview-plugins-design.md](plugins/dock-preview-plugins-design.md) | Dock 预览插件系统调研与设计 |
| [scene-api-alignment.md](plugins/scene-api-alignment.md) | Scene API 双分支对齐说明 |
| [plugin-3d-rendering-options-2026-11-06.md](plugins/plugin-3d-rendering-options-2026-11-06.md) | 插件通用 3D 场景与自由渲染层的对比及 C-D01 选型结论 |
| [plugin-scene3d-implementation-plan.md](plugins/plugin-scene3d-implementation-plan.md) | `scene3d` 实施设计，以音乐插件 iPod 为最终验收目标 |
| [plugin-scene3d-tasks.md](plugins/plugin-scene3d-tasks.md) | `scene3d` 子任务、依赖与阶段门禁 |
| [whale-plugin-progress.md](plugins/whale-plugin-progress.md) | 鲸娘 Dock 预览插件进度与续接手册 |
| [plugin-preview-development-plan.md](plugins/preview/plugin-preview-development-plan.md) | 插件独立预览与开发工具方案 |
| [plugin-preview-development-tasks.md](plugins/preview/plugin-preview-development-tasks.md) | 预览工具任务书与分阶段取证 |
| [plugin-preview-contract.md](plugins/preview/plugin-preview-contract.md) | 预览工具内部契约 v1 |
| [plugin-preview-coverage.md](plugins/preview/plugin-preview-coverage.md) | 覆盖矩阵与失败清单 |
| [plugin-preview-guide.md](plugins/preview/plugin-preview-guide.md) | 开发者与 Agent 使用指南 |
| [plugin-preview-agent-isolation.md](plugins/preview/plugin-preview-agent-isolation.md) | Preview App 的 Agent 验证隔离方案 |

## 调研与评审

| 文档 | 内容 |
| --- | --- |
| [reviews/all-spaces-window-preview.md](reviews/all-spaces-window-preview.md) | 跨桌面窗口发现的实现与验证记录 |
| [reviews/glass-and-appearance-settings.md](reviews/glass-and-appearance-settings.md) | 玻璃与外观设置现状诊断 |
| [research/desktop-grid/](research/desktop-grid/) | 九宫格实验的探测脚本、夹具与观测数据 |

## 仓库其它入口

- [README.md](../README.md)、[README.zh-CN.md](../README.zh-CN.md)：能力、权限与构建概览
- [CONTRIBUTING.md](../CONTRIBUTING.md)：开发、设置兼容、日志与测试约定
- [AGENTS.md](../AGENTS.md)：目录职责、分层边界与交付自检

## 后台预览验证记录

| 文档 | 内容 |
| --- | --- |
| [plugin-preview-background-input-2026-11-10.md](reviews/plugin-preview/plugin-preview-background-input-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-background-integration-2026-11-10.md](reviews/plugin-preview/plugin-preview-background-integration-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-color-clock-2026-11-10.md](reviews/plugin-preview/plugin-preview-color-clock-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-hidden-window-feasibility-2026-11-10.md](reviews/plugin-preview/plugin-preview-hidden-window-feasibility-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-layer-fidelity-2026-11-10.md](reviews/plugin-preview/plugin-preview-layer-fidelity-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-renderer-color-lifecycle-2026-11-10.md](reviews/plugin-preview/plugin-preview-renderer-color-lifecycle-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-renderer-input-2026-11-10.md](reviews/plugin-preview/plugin-preview-renderer-input-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-view-capture-2026-11-10.md](reviews/plugin-preview/plugin-preview-view-capture-2026-11-10.md) | 后台预览输入、捕获或接入验证记录 |
| [plugin-preview-pr-rebase-2026-11-10.md](reviews/plugin-preview/plugin-preview-pr-rebase-2026-11-10.md) | 主干 rebase 后的提交候选、固定依赖验证与旧 iPod 夹具边界 |
| [plugin-preview-ipod-lock-2026-11-11.md](reviews/plugin-preview/plugin-preview-ipod-lock-2026-11-11.md) | 新版 iPod 不可变资产锁定、后台交互回归与 PR 待审验收 |

### MediaRemote 媒体桥

- [接入设计与门禁](plugins/mediaremote/music-mediaremote-integration-plan.md)
- [默认启动与真实 Dock 验收](reviews/music-mediaremote/music-mediaremote-default-startup-2026-11-10.md)
- [近期封面与上一首恢复](reviews/music-mediaremote/music-mediaremote-history-2026-11-10.md)
