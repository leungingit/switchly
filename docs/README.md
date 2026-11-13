# Switchly 文档索引

`docs/` 是仓库文档的唯一入口。根目录只保留 GitHub 社区健康文件（README、CONTRIBUTING、SECURITY、PRIVACY_POLICY、CODE_OF_CONDUCT、CHANGELOG、LICENSE）与构建入口（Makefile、project.yml、mise.toml、build.sh、verify.sh）。

文档按领域与任务主题归档，不同主题和任务划分到独立子目录隔离管理：

| 目录 | 放什么 | 典型子目录与专项 | 不放什么 |
| --- | --- | --- | --- |
| [product/](product/) | 产品形态、交互设计、设计系统与界面工程约束 | `desktop-grid/`（九宫格虚拟桌面专项） | 实施进度、验收记录 |
| [engineering/](engineering/) | 工程约束、性能与资源记录、发布流程 | 通用工程规范 | 产品构想 |
| [plugins/](plugins/) | 插件体系契约、API 参考、生态方案、各专项任务方案 | `preview/`（预览工具链）、`scene3d/`（3D 场景）、`mediaremote/`（媒体桥）、`whale/`（鲸娘插件） | 宿主通用界面规范 |
| [research/](research/) | 调研底稿、实验夹具与原始数据 | `desktop-grid/`（九宫格实验夹具与观测数据） | 结论性规范 |
| [reviews/](reviews/) | 特定改造的实现与验证记录 | `music-mediaremote/`（媒体桥验收）、`plugin-preview/`（预览输入隔离验收） | 目标方案 |
| [assets/](assets/) | 文档引用的全局图片与示意图 | `images/` | 构建期资源（放 `Resources/`） |
| [plan/](plan/) | 本机过程草稿 | 本地临时记录（该目录被 Git 忽略） | 需要长期维护的结论 |

命名沿用英文小写连字符；时间相关的评估、复盘用 `-YYYY-MM-DD` 后缀，过程草稿用 `YYYY-MM-DD-` 前缀。

---

## 产品与界面 (`docs/product/`)

### 通用设计规范

| 文档 | 内容 |
| --- | --- |
| [design-system.md](product/design-system.md) | 原生 macOS 界面的长期视觉规范，数值以共享实现为准 |
| [ui-guidelines.md](product/ui-guidelines.md) | SwiftUI / AppKit 的实现与验收约束 |

### 九宫格虚拟桌面专项 (`docs/product/desktop-grid/`)

| 文档 | 内容 |
| --- | --- |
| [desktop-grid-research-and-spec.md](product/desktop-grid/desktop-grid-research-and-spec.md) | 九宫格虚拟桌面：场景调研、性能判断与交互方案 |
| [desktop-grid-feasibility-2026-10-20.md](product/desktop-grid/desktop-grid-feasibility-2026-10-20.md) | 第一轮可行性研究（只读探测，未实现功能） |
| [desktop-grid-evaluation-2026-10-21.md](product/desktop-grid/desktop-grid-evaluation-2026-10-21.md) | 第二轮评估与立项判断 |
| [desktop-grid-design-spec.md](product/desktop-grid/desktop-grid-design-spec.md) | 设计定稿（工程尚未实施） |
| [desktop-grid-tasks.md](product/desktop-grid/desktop-grid-tasks.md) | 九宫格开发任务台账 |

---

## 工程与性能 (`docs/engineering/`)

| 文档 | 内容 |
| --- | --- |
| [RELEASING.md](engineering/RELEASING.md) | 版本号规则与发布流程（版本真源是 `Resources/Info.plist`） |
| [native-ui-automation.md](engineering/native-ui-automation.md) | 原生界面自动化：自行打开 Switchly 偏好设置、截图核验与失败定位 |
| [performance-review-2026-10-20.md](engineering/performance-review-2026-10-20.md) | 性能检查与优化记录 |
| [idle-performance.md](engineering/idle-performance.md) | 空闲截图开销排查（D01 已被 D02 部分取代） |
| [thumbnail-cache.md](engineering/thumbnail-cache.md) | 缩略图跨次启动复用的目标、边界与生命周期 |

---

## 插件生态 (`docs/plugins/`)

### 插件体系核心规范与架构

| 文档 | 内容 |
| --- | --- |
| [plugin-api-reference.md](plugins/plugin-api-reference.md) | 宿主插件公开 API 参考；机器可读清单在 `Plugins/api/` |
| [activity-timeline-plan.md](plugins/activity-timeline-plan.md) | 活动记录、独立插件面板、截图采样与分层授权合同 |
| [window-capture-plan.md](plugins/window-capture-plan.md) | 窗口截图合同、任务与范围；[验证记录](reviews/window-capture-validation-2026-11-11.md) |
| [plugin-api-roadmap.md](plugins/plugin-api-roadmap.md) | API / SDK 能力开放路线 |
| [plugin-ecosystem-plan.md](plugins/plugin-ecosystem-plan.md) | 插件外置化、管理机制与 API 标准化方案 |
| [plugin-externalization-progress.md](plugins/plugin-externalization-progress.md) | 外迁实施台账与已完成范围 |
| [dock-preview-plugins-design.md](plugins/dock-preview-plugins-design.md) | Dock 预览插件系统总调研与设计架构 |
| [scene-api-alignment.md](plugins/scene-api-alignment.md) | Scene API 双分支对齐说明 |

### 插件独立预览与测试工具链专项 (`docs/plugins/preview/`)

| 文档 | 内容 |
| --- | --- |
| [plugin-preview-guide.md](plugins/preview/plugin-preview-guide.md) | 开发者与 Agent 使用指南（命令由回归脚本执行） |
| [plugin-preview-contract.md](plugins/preview/plugin-preview-contract.md) | 预览工具内部契约 v1（CLI、App 与协议边界） |
| [plugin-preview-coverage.md](plugins/preview/plugin-preview-coverage.md) | 覆盖矩阵与未验证清单 |
| [plugin-preview-development-plan.md](plugins/preview/plugin-preview-development-plan.md) | 插件独立预览与开发工具原始方案 |
| [plugin-preview-development-tasks.md](plugins/preview/plugin-preview-development-tasks.md) | 预览工具任务书与分阶段取证记录 |
| [plugin-preview-agent-isolation.md](plugins/preview/plugin-preview-agent-isolation.md) | Preview App 的 Agent 验证隔离方案 |

### 3D 渲染与 Scene3D 实施专项 (`docs/plugins/scene3d/`)

| 文档 | 内容 |
| --- | --- |
| [plugin-3d-rendering-options-2026-11-06.md](plugins/scene3d/plugin-3d-rendering-options-2026-11-06.md) | 通用 3D 场景与自由渲染层对比及 C-D01 选型结论 |
| [plugin-scene3d-implementation-plan.md](plugins/scene3d/plugin-scene3d-implementation-plan.md) | `scene3d` 实施设计（以 iPod 为最终验收目标） |
| [plugin-scene3d-tasks.md](plugins/scene3d/plugin-scene3d-tasks.md) | `scene3d` 子任务、依赖与阶段门禁 |

### MediaRemote 媒体桥接入专项 (`docs/plugins/mediaremote/`)

| 文档 | 内容 |
| --- | --- |
| [music-mediaremote-integration-plan.md](plugins/mediaremote/music-mediaremote-integration-plan.md) | Apple Music 的 MediaRemote 接入契约、任务与门禁 |

### 鲸娘插件专项 (`docs/plugins/whale/`)

| 文档 | 内容 |
| --- | --- |
| [whale-plugin-progress.md](plugins/whale/whale-plugin-progress.md) | 鲸娘 Dock 预览插件进度与续接手册 |

---

## 调研与评审 (`docs/reviews/` & `docs/research/`)

### 系统功能验证记录 (`docs/reviews/`)

| 文档 | 内容 |
| --- | --- |
| [all-spaces-window-preview.md](reviews/all-spaces-window-preview.md) | 跨桌面窗口发现的实现与验证记录 |
| [glass-and-appearance-settings.md](reviews/glass-and-appearance-settings.md) | 玻璃与外观设置现状诊断 |
| [menu-bar-appearance-2026-11-13.md](reviews/menu-bar-appearance-2026-11-13.md) | 菜单栏主题污染修正、真实状态项回归及正式合成色对照限制 |
| [activity-timeline-integration-2026-11-13.md](reviews/activity-timeline-integration-2026-11-13.md) | 双仓提交前复核、单测隔离、历史截图及失效批次修正与验收边界 |
| [activity-timeline-implementation-2026-11-12.md](reviews/activity-timeline-implementation-2026-11-12.md) | 活动时间线实现、937项单测、趋势图、纵向会话／截图及实机验收边界 |
| [activity-tracking-incident-2026-11-13.md](reviews/activity-tracking-incident-2026-11-13.md) | AT-INC01：验收误清除、331条原始区间恢复、截图恢复限制及确认入口安全修正 |
| [活动追踪连续实机验收窗口](../Tools/ActivityTrackingAcceptance/README.md) | 自动前台区间、撤权／恢复与真实600秒冷却的验收辅助窗口 |
| [activity-tracking-plan-review-2026-11-12.md](reviews/activity-tracking-plan-review-2026-11-12.md) | 活动时间线分支方案评审、计时与隐私缺口、分阶段推进建议 |

### MediaRemote 媒体桥接入验收 (`docs/reviews/music-mediaremote/`)

| 文档 | 内容 |
| --- | --- |
| [music-mediaremote-probe-2026-11-10.md](reviews/music-mediaremote/music-mediaremote-probe-2026-11-10.md) | 独立媒体探针流媒体封面、快速切歌与浏览器抢占实测摘要 |
| [music-mediaremote-implementation-2026-11-10.md](reviews/music-mediaremote/music-mediaremote-implementation-2026-11-10.md) | MR-T01／MR-T02 离线依赖、进程封装与状态机实施和测试记录 |
| [music-mediaremote-t03-t04-2026-11-10.md](reviews/music-mediaremote/music-mediaremote-t03-t04-2026-11-10.md) | MR-T03／MR-T04 候选组合桥、原子展示、共享兴趣与图片预算 |
| [music-mediaremote-t05-t06-architecture-2026-11-10.md](reviews/music-mediaremote/music-mediaremote-t05-t06-architecture-2026-11-10.md) | MR-T05／MR-T06 注入面板、Safari 抢占、共享 VM 与短锁整改及候选打包 |
| [music-mediaremote-default-startup-2026-11-10.md](reviews/music-mediaremote/music-mediaremote-default-startup-2026-11-10.md) | 组合媒体桥正常启动接入与真实 Dock 悬停验收 |
| [music-mediaremote-history-2026-11-10.md](reviews/music-mediaremote/music-mediaremote-history-2026-11-10.md) | MR-D12 上一首重播屏障、近期封面缓存与实际延迟边界 |

### 独立预览后台输入隔离验收 (`docs/reviews/plugin-preview/`)

| 文档 | 内容 |
| --- | --- |
| [plugin-preview-background-input-2026-11-10.md](reviews/plugin-preview/plugin-preview-background-input-2026-11-10.md) | 合成后台窗口的外部 AX、进程内驱动与指定窗口坐标事件对照及未验边界 |
| [plugin-preview-renderer-input-2026-11-10.md](reviews/plugin-preview/plugin-preview-renderer-input-2026-11-10.md) | 真实共享 Renderer 的 2D／3D 后台输入、负向回归及完全屏幕外捕获失败边界 |
| [plugin-preview-view-capture-2026-11-10.md](reviews/plugin-preview/plugin-preview-view-capture-2026-11-10.md) | 完全屏幕外的原生视图缓存、真实 SceneKit 快照与分层合成闭环及保真边界 |
| [plugin-preview-layer-fidelity-2026-11-10.md](reviews/plugin-preview/plugin-preview-layer-fidelity-2026-11-10.md) | 分层捕获与原生参考的保真度、裁剪遮挡、真实爱心动画及同帧一致性边界 |
| [plugin-preview-color-clock-2026-11-10.md](reviews/plugin-preview/plugin-preview-color-clock-2026-11-10.md) | 固定显示器与颜色空间漂移、原生玻璃缓存差异及显式 SceneKit 时间回放校准 |
| [plugin-preview-renderer-color-lifecycle-2026-11-10.md](reviews/plugin-preview/plugin-preview-renderer-color-lifecycle-2026-11-10.md) | 真实 Renderer 颜色矩阵、启动前激活监测、显式时间不能固定产品相机的反例与恢复边界 |
| [plugin-preview-hidden-window-feasibility-2026-11-10.md](reviews/plugin-preview/plugin-preview-hidden-window-feasibility-2026-11-10.md) | 不排序原生窗口的真实后台截图与输入闭环、透明初始化失败、无前台占用证据及可行性裁决 |
| [plugin-preview-background-integration-2026-11-10.md](reviews/plugin-preview/plugin-preview-background-integration-2026-11-10.md) | 隐藏表面正式接入、标签与 SceneKit 输入、独立隔离观察、错误退出码和 SIGTERM 清理回归 |

### 实验与研究夹具 (`docs/research/`)

| 目录 | 内容 |
| --- | --- |
| [desktop-grid/](research/desktop-grid/) | 九宫格实验的探测脚本、夹具与观测数据 |

---

## 仓库其它入口

- [README.md](../README.md)、[README.zh-CN.md](../README.zh-CN.md)：产品能力、权限与构建概览
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
