# 插件独立预览：覆盖矩阵与失败清单

日期：2026-11-03（T17 / G2 交付物）；2026-11-04 增补进行中的改造项。本文只记录**已有命令实际验证过的事实**；「未验证」栏是缺口，不是已完成项。
命令均从仓库根目录执行；GUI 类脚本需要图形会话与屏幕录制授权，环境不可用时退出码为 77（既不是通过，也不是缺陷）。

## 1. 验证层次（互相不能替代）

| 层次 | 证明什么 | 不能证明什么 |
| --- | --- | --- |
| 契约 | 场景/fixture/报告/协议/Schema 的形状与错误码 | 插件业务是否正确 |
| 业务动作（`action` 步骤） | 直接调用插件 `onAction` 后状态变化 | 控件是否可点击、标签是否可读 |
| 原生输入（`nativeClick` 步骤） | 经可访问树按标签 press，动作经 SwiftUI 回调进入会话；禁用控件不触发 | 系统级鼠标事件、hover、键盘焦点、滑块调节 |
| 视觉（`baseline`） | 确定时钟、非玻璃场景下像素级可比较、差异可定位 | 真实桌面玻璃效果 |
| 真实系统集成 | 仍由本体承担：Dock、AX 切窗、跨屏、玻璃背景 | 本工具不验证，也不声称验证 |

## 2. 覆盖矩阵

| 能力 | 验证命令 | 实际结果 | 未验证 / 限制 |
| --- | --- | --- | --- |
| 契约哈希、渲染器 revision、共享源码 | `make plugin-preview-contract-check` | 三项一致；人为改坏常量/复制核心类型均返回非零 | revision 覆盖 12 个共享渲染源文件，不含资源图片 |
| 场景与步骤解析（含严格键、上限、未知类型） | `bash Tools/PluginPreview/Scenario/run-tests.sh` | 通过 | — |
| 步骤执行器（失败即停、skipped、取消、不可用/禁用/歧义动作） | 同上 | 通过 | — |
| 帧协议（截断/超限/非法 UTF-8/版本） | `bash Tools/PluginPreview/Protocol/run-tests.sh` | 8 项通过 | — |
| 会话与监督（卡死回收、取消、generation、watchdog 升级 kill） | `bash Tests/PluginPreview/run-session-tests.sh`、`run-process-supervisor-tests.sh` | 5 + 7 项通过 | — |
| worker（fixture 预算、流隔离、虚拟时钟 `advance` 正反用例） | `bash Tools/PluginPreview/Worker/Tests/run-tests.sh` | 通过 | — |
| 产物与报告（steps trace、失败报告、不覆盖输出） | `bash Tools/PluginPreview/Artifacts/run-tests.sh` | 通过 | — |
| 虚拟时钟 Runtime（Date/Math.random/定时器、有界触发、默认路径不变） | `make test-unit`（`PluginVirtualClockTests`） | 551 项，8 跳过，0 失败 | — |
| CLI 参数、结果对象、信号转发、baseline | `npm --prefix Plugins/cli test` | 33 项通过 | — |
| 外仓场景契约与校验 | 外仓 `npm test` | 32 项通过 | 需先用离线 CLI 包执行 `validator:prepare` |
| 原生输入（按钮/禁用/开关/Scene 命中区域） | `make plugin-preview-native-test` | 正向 + 4 个负向通过 | 滑块、hover、键盘、系统级鼠标事件 |
| 视觉基线（一致、差异检出、玻璃拒绝） | `make plugin-preview-baseline-test` | 通过 | 环境不兼容的组合只验证了拒绝逻辑（JS 测试），未在第二台机器上实测 |
| dev 生命周期（重载、损坏保留旧画面、恢复、SIGINT 后无残留） | `bash Tests/PluginPreview/run-dev-lifecycle-tests.sh` | 通过 | 隐藏/最小化触发 suspend/resume 未自动化 |
| 失败模式（12 种常见错误得到稳定且可区分的状态+错误码+退出码；死循环 worker 被回收） | `bash Tests/PluginPreview/run-failure-modes-tests.sh` | 12/12 通过 | 表中未列出的错误回落到 `preview-failed` |
| 版本握手（`--version-json`；契约/协议/场景/工具/插件 API 不配套时启动前拒绝） | `npm --prefix Plugins/cli test`、工具包验收 | 通过；JS 与 Swift 契约哈希一致（真实 App 对比） | — |
| 离线工具包（Release、ad-hoc、清单、SHA256SUMS；无 Xcode/无网络/空 HOME 运行） | `make plugin-preview-toolkit-test` | 通过（沙箱经 curl 验证确实阻断网络）；arm64 与 x86_64（Rosetta）实测 | 原生 Intel、macOS 12 未验；未公证 |
| 干净环境演练（只有插件仓库 + 工具包；validate→run→读报告/截图→基线→改动检出→恢复通过；产物不含本机路径） | `make plugin-preview-cleanroom` | 通过 | 外仓为私有仓库，CI 未接入此项（本地/手动） |
| 使用指南中的命令（`quickstart`、`agent-loop` 块原样提取执行） | `bash Tests/PluginPreview/run-guide-check.sh <工具包>` | 通过 | 其余示例命令以回归脚本为准 |
| 分层 CI（static / jsc / gui） | `.github/workflows/ci.yml` | YAML 语法与 action 版本核对；**未在 GitHub 上实际运行** | `preview-gui` 仅在配置 `PREVIEW_GUI_RUNNER` 时运行，否则显示为跳过 |
| 外仓全部场景（14 个）+ 4 个确定性场景两次逐字节一致 | `make plugin-preview-regression` | 14/14 通过 | 玻璃场景仅作证据，不比较像素 |
| 本体回归 | `make build`、`make test-unit` | 构建成功；551 项 0 失败 | — |

## 3. 已发现并修复的缺陷（失败清单）

| 编号 | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| F01 | 只向 CLI 进程发 SIGINT/SIGTERM 时，预览 App 与 worker 变成孤儿 | CLI 不转发信号；终端 Ctrl-C 因整组投递而掩盖了问题 | CLI 转发 SIGINT/SIGTERM/SIGHUP，10 秒后升级 SIGKILL；`preview.test.js` 回归（撤掉修复时失败，已验证） |
| F02 | 固定时钟下 Scene 仍随墙上时间变化 | 截图表面没有注入虚拟时间 | `pluginSceneNow` 环境值；三次运行截图字节一致 |
| F03 | 场景 `clock` 内未知键被宽松接受 | 只依赖 `Decodable` | 增加键白名单与负向测试 |
| F04 | 渲染抛错、非法 UI、manifest 损坏、场景非法、缺 fixture、死循环全部折叠为同一个 `preview-failed` | 失败出口没有分类 | 稳定的 kebab-case 错误码 + 固定提示（不回显内容）；`run-failure-modes-tests.sh` 固化 |
| F05 | 用 `create` 脚手架直接 `run` 得到「环境不可用」（退出 4），误导作者以为 GUI/授权坏了 | 插件只渲染未截图的槽位，被归入环境错误 | 区分 `no-capturable-slot`（3）与 `empty-render`（1） |
| F06 | 工具包验收偶发「ad-hoc 签名」失败（141） | `codesign \| grep -q` 在 `pipefail` 下被 SIGPIPE | 先捕获再匹配；连跑 5 次稳定 |
| F07 | 使用指南的 Agent 示例在 `bash -e` 下无声退出 | `$(...)` 失败在读取 `$?` 前即退出 | 示例改为 `&& code=0 \|\| code=$?`；文档块被脚本原样执行 |
| F08 | Release 构建暴露两条编译警告（Sendable 捕获、Selector 字面量） | 我引入的代码；Debug 增量构建未重报 | 根治，不加豁免（本项目把警告当错误） |

## 4. 仍未验证的范围

- 滑块调节、hover、键盘导航与焦点可见性（T15 验收项）。
- 窗口隐藏/最小化触发的 `suspend`/`resume` 端到端。
- fixture 更新类步骤（T14 计划项，未实现）。
- macOS 12、Intel、无图形会话（仅验证了「环境不可用时返回 77/退出码 4」的逻辑分支，未在对应环境实测）。
- 真实 Dock、AX 切窗、跨屏与桌面玻璃：不属于本工具范围，仍按 AGENTS.md 在本体验证。

## 5. 性能基线与观察（T21）

实测于 Apple M4 Pro / macOS 27.0.1 / 24 GiB，Release 工具包，`Tests/PluginPreview/measure-baseline.sh`；只记录，不设阈值。

| 项 | 实测 |
| --- | --- |
| `run` 端到端（CLI→App→worker→截图→退出，n=5） | 首次 3858 ms；其余 1213–1234 ms（中位 1234 ms） |
| `dev` 重载延迟（保存→新一代就绪，含整包校验，n=5） | 329–364 ms（中位 359 ms） |
| `dev` 静止 10 s | 预览 App：平均 CPU 0.6%，RSS 102 MiB；worker：平均 CPU 0.0%，RSS 15 MiB |
| 退出清理 | SIGINT → CLI 88 ms 退出，无残留后代进程 |

观察（非预览缺陷）：音乐卡片在 240 pt 窄宽度下溢出——标题被右边缘截断，右上角图标被裁。预览与本体共用渲染代码，这是渲染器/插件布局在窄宽度下的行为；已记为后续事项，本任务未改动。

## 6. 2026-11-04 改造（进行中，无验证结论）

以下为默认场景、覆盖项、`inspect`、GUI 启动器、两栏启动器与模拟 Dock、工作台舞台与原始桌面透射、内置合成样例与缺数据提示改造的覆盖计划。状态全部是**实现中**，尚未执行对应回归，不得视为通过；实现落地后应把实际命令与结果替换进本表，不能只保留计划。

| 能力 | 计划验证命令 | 当前状态 | 未验证 / 限制 |
| --- | --- | --- | --- |
| 默认场景推导（`id`/环境/目标/授权/固定时钟） | 场景单元测试、`switchly-plugin inspect --json` | 实现中 | 未运行回归 |
| 覆盖项解析、互斥（`--scenario` + 覆盖项 → 2）与类型校验 | CLI `npm test`、App 参数测试 | 实现中 | 未运行回归 |
| `scenarioSource` 写入结果与 `report.json` | CLI/产物测试、`run-guide-check.sh` | 实现中 | 未运行回归；旧报告兼容读取未实测 |
| `inspect` 输出结构、错误分类与退出码 | CLI `npm test`、实际 App 调用 | 实现中 | 无 GUI/无授权分支未实测 |
| `create` 默认渲染 `center` 与 `main.js` 模板 | `run-guide-check.sh`、`create` 后直接 `run` | 实现中 | 未运行 |
| fixture 选择（media/weather 内置、fs 显式文件、复制进 `workRoot`、相对路径、大小/路径校验） | 单元测试、CLI 透传测试 | 实现中 | 未运行回归 |
| 内置样例与缺数据提示：media/weather 自动附加、`fs.read` 需要显式文件、显式文件覆盖内置、GUI 清除不回退、`inspect.fixtures[].source`、`plugin-script-error` 的固定修复文案（无本机路径） | 场景/失败模式回归、`inspect --json`、实际 `run` | 实现中 | 未运行回归；内置样例资源与三处提示一致性未核对；无截图证据 |
| GUI 控件可访问标签（「打开插件目录…」、模式切换、各编辑控件、fixture 选择/清除） | 可访问性/原生输入回归、手动 GUI 检查 | 实现中 | 未运行回归；无 AX 实机证据 |
| GUI 启动器：选择/拖入/最近使用/默认/自定义/导出场景 | 手动 GUI 检查 + 阅读截图 | 实现中 | 需要图形会话与屏幕录制授权；本轮没有截图证据 |
| 两栏启动器与模拟 Dock（左右分栏、<900 pt 纵向堆叠、目标图标悬停 0.4 s/离开 0.3 s、切换即时、浮层居中且限制在右栏、`center`/`bottomBar` 按本体规则挂载、固定占位图标不响应） | 手动 GUI 检查 + 阅读截图；可访问标签/原生输入回归 | 实现中 | 未运行回归；无截图证据；`topTrailing`/`titleAccessory` 本体未接入，不在模拟 Dock 验证；真实 AX 悬停/跨屏/真实缩略图/桌面玻璃合成仍由本体承担 |
| 工作台舞台与原始桌面透射（控制区不透明且收窄、右栏默认有标题和舞台背景、切换后右栏与标题栏底色清空、左栏保持不透明） | 手动 GUI 检查 + 阅读普通/原始桌面模式截图 | 已检查 | 2026-11-05：1080×720 Debug 启动器；实际查看默认舞台、原始桌面、英文与简体中文截图；`Tools/PluginPreview/Scenario/run-tests.sh` 通过。未覆盖 <900 pt 堆叠与不同桌面背景；玻璃外观不得作为视觉基线 |
| 静态检查（参数名与文档一致、`git diff --check`） | `grep` 校对、`git diff --check` | 本次文档修改已执行 | 只证明文本一致，不证明实现 |

本轮文档修改的验证仅为文本一致性检查（参数名与规格、链接、`git diff --check`，以及从指南提取的 `quickstart`/`agent-loop` 块 `bash -n`）；它不能替代上述任何运行时回归。
