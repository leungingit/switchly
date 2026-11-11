# Switchly 插件体系文档索引

本文档是 `docs/plugins/` 目录的结构导引与分类索引。本目录统一维护 Switchly 插件系统的公开契约、系统设计、路线图以及各专项任务方案。

---

## 1. 核心架构与公共契约

保留在 `docs/plugins/` 顶层，是插件体系的通用设计与公开真源：

| 文档 | 职责说明 |
| --- | --- |
| [dock-preview-plugins-design.md](dock-preview-plugins-design.md) | Dock 预览插件系统总架构设计、历史阶段与决策台账（D01～D26） |
| [plugin-api-reference.md](plugin-api-reference.md) | 宿主面向插件的公开 API 参考规范（核心公开契约真源；机器可读清单在 `Plugins/api/`） |
| [plugin-api-roadmap.md](plugin-api-roadmap.md) | API / SDK 能力开放路线图（R0～R5 规划） |
| [plugin-ecosystem-plan.md](plugin-ecosystem-plan.md) | 插件外置化、隔离模型与生态标准化方案 |
| [plugin-externalization-progress.md](plugin-externalization-progress.md) | 插件外迁实施进度与已完成范围台账 |
| [scene-api-alignment.md](scene-api-alignment.md) | 2D Scene API 双分支规范对齐说明 |

---

## 2. 专项任务与主题子目录

各具体任务与独立工具链按主题划分入独立子目录，避免平铺混淆：

### 独立预览与测试工具链 (`preview/`)
放置插件独立开发、预览 App、CLI 工具包与测试套件的相关文档：
- [使用指南](preview/plugin-preview-guide.md)：面向插件开发者与 Agent 的端到端操作指南
- [内部契约 v1](preview/plugin-preview-contract.md)：预览 App、CLI 与协议边界的权威定义
- [覆盖矩阵](preview/plugin-preview-coverage.md)：工具包覆盖范围、测试与已知未验证项
- [开发方案](preview/plugin-preview-development-plan.md)：独立预览工具原始架构设计
- [开发任务书](preview/plugin-preview-development-tasks.md)：T00～T21 任务分解与分阶段取证
- [Agent 验证隔离方案](preview/plugin-preview-agent-isolation.md)：后台运行与无窗口焦点干扰方案

### 3D 渲染与 Scene3D 实施 (`scene3d/`)
放置 3D 资产、glTF/GLTFKit2 加载与 Scene3D 原生渲染专项：
- [3D 渲染方案对比](scene3d/plugin-3d-rendering-options-2026-11-06.md)：通用 3D 场景与自由渲染层对比及 C-D01 选型
- [实施方案设计](scene3d/plugin-scene3d-implementation-plan.md)：`scene3d` 架构设计与 iPod 落地方案
- [任务书与门禁](scene3d/plugin-scene3d-tasks.md)：T00～T09 实施任务台账与各阶段门禁

### MediaRemote 媒体桥接入专项 (`mediaremote/`)
放置 Apple Music 系统级媒体信息采集与组合桥接入方案：
- [MediaRemote 最小接入设计](mediaremote/music-mediaremote-integration-plan.md)：Apple Music 流媒体封面与 MediaRemote 接入契约

### 鲸娘 Dock 预览插件专项 (`whale/`)
放置特定形象插件的专属进度手册：
- [鲸娘插件进度与续接手册](whale/whale-plugin-progress.md)：立绘分层、动作时间线与阶段小样进度

---

## 3. 关联验收记录

各专项的真实系统环境与宿主验收记录归档在 `docs/reviews/` 对应子目录：
- 媒体桥接入验收：[docs/reviews/music-mediaremote/](../reviews/music-mediaremote/)
- 独立预览后台输入验收：[docs/reviews/plugin-preview/](../reviews/plugin-preview/)
