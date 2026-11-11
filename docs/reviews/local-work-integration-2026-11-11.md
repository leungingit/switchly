# 本地剩余修改集成验证（2026-11-11）

## LW-D01：范围与基线

基于 `main@88b418e`，收录 Electron／Chromium 返回 `apiDisabled` 时启用辅助功能树并重新枚举窗口的修改，以及 Scene3D、鲸娘和九宫格文档分类迁移。重叠内容沿用已合并主干版本，插件锁、公开契约和渲染器 revision 保持主干值。文档索引去除重复条目，相对链接随迁移调整。

## 实际验证

- `make build` 成功。
- `make test-unit` 复验为 804 项、9 项条件跳过、0 失败，输出 `TEST SUCCEEDED`。首次完整运行的 `DockPreviewPanelRefreshTests.testWindowListRefreshDoesNotReframeVisiblePanel` 观察到一次额外 frame 设置而失败；该项单独运行及完整套件复验均通过。未改变测试断言或跳过该项，首次失败根因尚未确定。
- `make mediaremote-adapter-test`：13 项通过。
- `make plugin-preview-contract-check`：契约哈希、渲染器 revision 和 33 个共享类型守卫通过。
- 插件外仓从锁定 revision `c2487864ae70e877ee539291884f4ae6e807fd11` 离线归档，46 项测试通过，双发行线构建和宿主逐文件哈希校验通过。
- 实际 AX 探针可枚举本机正在运行的 Chrome、VS Code 和 Codex；返回码均为成功，未触发 `apiDisabled`。该异常状态的真实恢复、最小化恢复与聚焦行为仍未验证。
- Markdown 相对链接扫描仅剩 `.taste-design/work/qa/manual-checks.md` 的本地忽略资料引用。`git diff --check` 与暂存区空白检查通过。

本轮无界面布局或材质变更。构建出现本机 CoreSimulator 版本提示，但 macOS 构建与单元测试成功。按 AGENTS 第 8 节核对，本次无新依赖、权限或设置；系统行为未验项如上，临时脚本、制品和日志位于系统临时目录。
