# MR-D13：MediaRemote 提交与 PR 收尾

日期为 2026-11-11。用户授权本次 MediaRemote 实现提交、推送并创建 PR。

## 范围与依赖

从 PR #27 分支 `feat/plugin-preview-background` 的提交 `000c219` 建立独立 `feat/mediaremote-music` 分支。复用其共享 3D 渲染及固定插件制品；MediaRemote 的离线 Adapter、状态机、组合桥、共享兴趣、原子展示与近期封面缓存作为独立差异提交。原开发工作区的已有暂存、未提交内容与插件外仓均保留。收尾期间 #27 更新基线后，已 rebase 并保留双方文档索引，再按新版固定制品复验。

插件制品从锁定的 `switchly-plugins@c2487864ae70e877ee539291884f4ae6e807fd11` 归档，在系统临时目录通过宿主离线 CLI 校验包准备、测试和构建。锁文件、公开 API、渲染器 revision 和 SDK 契约哈希保持基线值。CI 增加本次叠加分支的 PR 触发及离线依赖的 13 项打包保护测试。

收尾补齐原子展示的 `slotsPublisher` 消费方，以及 Worker／Session 独立测试的共享类型编译输入，避免只在原脏工作区编译通过。

## 实际验证

- 外仓固定源码 `npm test` 为 46 项通过，`npm run build` 生成两个发行线，宿主使用 v2 锁定制品。
- `make generate`、`make build` 成功。
- `make test-unit` 为 804 项，9 项条件跳过，0 失败，输出 `TEST SUCCEEDED`。当前工具链仍报告原有测试替身的 Swift 6 actor 隔离预告与 CoreSimulator 版本提示，主 App 的警告门禁构建通过。
- `make mediaremote-adapter-test` 为 13 项通过。
- `make plugin-preview-contract-check` 成功，包含公开契约、渲染器 revision 和 33 个共享核心类型守卫。
- `Tools/PluginPreview/Worker/Tests/run-tests.sh` 输出 `PluginPreviewWorker tests passed`。
- `Tests/PluginPreview/run-session-tests.sh` 输出 `SUMMARY passed=5 failed=0`。
- 包内 Adapter 的 `lipo -archs` 输出 `x86_64 arm64`；主 App 的 `codesign --verify --deep --strict` 成功。
- `git diff --check` 通过。

本轮收尾复核了前轮实际 Dock 悬停截图，沿用 2026-11-10 的真实运行记录，没有把本次隔离工作树构建冒充为新的桌面验收。真实截图确认流媒体封面最终一致，早期仍可能出现短暂占位；同曲重播特殊分支由状态机测试覆盖。跨系统／Intel 真机、真实睡眠、完整主题矩阵及发行签名公证继续按设计门禁保留未验状态。

## 交付自检

按仓库 AGENTS 第 8 节核对，任务范围、依赖方向、主线程展示、短锁、共享兴趣与停止路径均沿用已测实现。无新设置或用户文案入口，无运行时联网或磁盘封面缓存；双语 README、隐私说明、变更记录和索引同步。临时制品、外仓归档与日志均位于系统临时目录，源工作区无收尾临时文件。PR 合并仍由用户决定。
