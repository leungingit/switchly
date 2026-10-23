# Spaces 受控评估夹具

对应 [第二轮评估结论](../../../desktop-grid-evaluation-2026-10-21.md)。这是独立研究夹具，不是 Switchly 功能，也不加入工程、依赖、设置或发行包。

## 用途与范围

- GridProbe 创建两个自有窗口及控制窗口，读取真实 Space 结构与成员关系；测试最小化、全屏、旧/bridged 窗口移动及两种桌面状态操作。
- ForeignFixture 创建另一个进程的两个测试窗口。控制器只接受该夹具的 bundle ID、PID 与 CG 窗口所有者均匹配的目标；不处理用户应用窗口。
- 不创建普通桌面，不删除桌面，不修改系统设置，不申请权限。切换实验会影响当前会话；全屏实验会临时产生系统全屏 Space；程序恢复与视觉恢复仍需分别确认。
- 没有截图逻辑、网络或遥测。`control.jsonl` 包含会话 Space 标识、类型和测试窗口状态，写入临时目录。分享前使用脱敏后的摘要，不提交原始截图。

## 构建与运行

在仓库根目录运行：

```sh
probe_root=$(bash docs/research/desktop-grid/control-fixture/build-fixtures.sh)
```

脚本只编译并生成临时 `.app`，不会启动程序或改变桌面。需要实测时，在两个终端分别启动：

```sh
GRID_PROBE_OUTPUT="$probe_root" "$probe_root/ForeignFixture.app/Contents/MacOS/ForeignFixture"
```

```sh
GRID_PROBE_OUTPUT="$probe_root" "$probe_root/GridProbe.app/Contents/MacOS/GridProbe"
```

两个终端中的 `probe_root` 必须指向同一个构建目录。启动后先等测试窗口被系统纳入 Space，再检查日志；刚创建时短暂返回空成员不等同于永久无归属。

选择单项测试，等待恢复记录后再执行下一项。系统切换和焦点测试串行进行，不同时运行其他桌面实验。退出前用 “Restore original Space” 核对原始 current 值，并目视检查场景；控制器只在该值与初始值一致时允许正常退出。ForeignFixture 用其应用菜单退出，测试窗口随进程关闭。

## 证据解释

**`getterMatched` 仅表示连续读取到目标 Space ID，不表示画面、焦点或输入路由已切换。** 控制窗口使用 all-Spaces 行为，控制器仍可见本身不能证明或否定切换；需要普通测试窗口、系统总览、实际显示器画面共同核验。

当时原始实验代码曾将该字段命名为 `confirmed`；[脱敏记录](../control-observations.json)保留其原始字段并附解释。此处归档代码修正为 `getterMatched`，移除了未执行且会误计为成功的 100 次重复切换入口，并将固定输出路径改为 `GRID_PROBE_OUTPUT`。归档代码与早期实验构建不逐字相同，核心接口路径相同；不要把编译验证写成全部实验已重新运行。

旧接口对自身窗口有效不代表可控制其他进程；bridged 窗口成员变更也只证明受控样本，不代表所有应用、全屏/最小化窗口或实际视觉行为均通过。

## R2 闭环切换探针

`switch-closed-loop-probe.m` 对应评估报告 §9，由 `build-fixtures.sh` 一并编译为 `ClosedLoopProbe.app`。同一可执行文件有两种角色：控制器会启动两个自身的夹具子进程（`--fixture`），分别放在原桌面和目标桌面（bridged 窗口移动放置），然后串行尝试各切换路径，每条路径最多 3 次、每次不超过 3.5 s、整体上限 150 s，并对每次尝试记录五个独立信号（公开通知、夹具自报、CG 在屏列表、F19 输入路由、SkyLight getter 仅作辅助）。

```sh
export GRID_PROBE_BUILD_ROOT="$TMPDIR/desktop-grid-r2"   # 可选：把构建产物放到系统临时目录
probe_root=$(bash docs/research/desktop-grid/control-fixture/build-fixtures.sh)
"$probe_root/ClosedLoopProbe.app/Contents/MacOS/ClosedLoopProbe" --out "$probe_root/r2.json"
"$probe_root/ClosedLoopProbe.app/Contents/MacOS/ClosedLoopProbe" --status   # 只读诊断：新窗口落在哪个 Space
```

可选环境变量：`R2_TARGET_SPACE_ID`（改用另一个普通 Space 作目标；非相邻时跳过 A）、`R2_PATHS`（逗号分隔的路径名前缀，只跑所选路径）。运行会真实切换桌面，期间不要操作键盘鼠标。

- 合成按键（路径 A、信号 4）需要启动进程具备合成输入权限，AX 路径（B2）需要辅助功能权限；缺失时对应路径记为 inconclusive 且不发送任何事件。F19 仅在最前应用是夹具时才发送。
- 不修改偏好、热键或 Dock，不截图；系统“切换到桌面 N”热键只有本来就启用时才会测试。
- **bridged `SetCurrentSpace` 会让被触及的 Space 留下“幽灵”状态并使后续原生激活切换失效，且非相邻切换可能被系统按最近使用重排。** 运行前后核对 Space 顺序，必要时由用户在 Mission Control 中复原。
- 结果解释与规则见评估报告 §9 和 [r2-switch-observations.json](../r2-switch-observations.json)。

## R2b 有权限补测

`run-r2b.sh` 对应评估报告 §10。它需要运行它的终端已获得辅助功能和输入监控，并且**直接在 shell 里执行探针可执行文件**（不用 `open`），这样 TCC 责任进程是终端；探针只做 ad-hoc 签名，不借用其他 App 的身份。

```sh
export GRID_PROBE_BUILD_ROOT="$TMPDIR/desktop-grid-r2b"
probe_root=$(bash docs/research/desktop-grid/control-fixture/build-fixtures.sh)
codesign -s - -f "$probe_root/ClosedLoopProbe.app"
"$probe_root/ClosedLoopProbe.app/Contents/MacOS/ClosedLoopProbe" --preflight   # 只读：四项权限预检 + Space 结构 + 窗口普查，不发事件
bash docs/research/desktop-grid/control-fixture/run-r2b.sh "$probe_root"
```

- `--preflight` 只调用 `AXIsProcessTrusted` 和 `CGPreflight*`，从不调用会弹授权框的 request API。
- `run-r2b.sh` 临时启用符号热键 118–126（默认 Control+1…9），结束时用 `defaults import` 还原并读回比较；备份、前后状态写入构建目录。它按显示器分别运行：显示器 0（有空桌面时）和显示器 1（把原桌面移到端点以获得非相邻目标）。显示器和起点由 `R2_DISPLAY_INDEX`、`R2_ORIGIN_SPACE` 控制，`R2_SCENARIOS`、`R2_PATHS`、`R2_BUDGET`、`R2_MAX_ATTEMPTS` 可缩小范围。
- 本版探针**已删除 bridged SetCurrentSpace**，恢复只用 B1（激活原桌面夹具）或临时启用的系统快捷键。若运行中途被打断，需要用户自行核对每个显示器的当前桌面。
- 系统快捷键使用**跨显示器的全局桌面编号**，并且跟随当前顺序（可能被自动重排改变）；探针在按键时重算。
- 到达证明使用无窗口夹具新建的窗口，只对拥有活动焦点的显示器有效。
- 结果与判定规则见评估报告 §10 和 [r2b-switch-observations.json](../r2b-switch-observations.json)。

## R3 手势捕获探针

`gesture-probe.m` 对应评估报告 §11，是独立命令行工具，不加入 `build-fixtures.sh`。它通过 `dlopen`/`dlsym` 使用私有 MultitouchSupport（不链接），注册触控板回调，按 JSON Lines 输出 `symbols`、`devices`、`frame`（手指数、质心、每指归一化坐标）、`session_start`、`swipe`（八方向）、`session_end`，并在结束时 stop/unregister。无触摸时不产生帧。不发送任何事件、不修改系统设置、不联网。

```sh
probe=$(bash docs/research/desktop-grid/control-fixture/build-gesture-probe.sh)   # 产物在 $TMPDIR/desktop-grid-gesture/，仅 ad-hoc 签名
"$probe" --list-only                       # 只枚举设备
"$probe" --duration 30 > "$TMPDIR/desktop-grid-gesture/run.jsonl"
```

选项：`--duration 秒`（默认 20）、`--no-frames`、`--min-fingers 4`、`--threshold-mm 12`、`--cooldown-ms 350`、`--dropout-ms 80`。`GRID_PROBE_BUILD_ROOT` 可改变构建目录。手测步骤与判读见评估报告 §11.3。该工具只是研究探针：私有接口随时可能变化；触点结构按布局事实自行声明，未拷贝第三方源码。

Mach-O 查找辅助代码来自 yabai 固定提交 `dd845723416f5fe92af49fad5ebab00369e07edd`，原文件为 `src/misc/macho_dlsym.h`，保留 [MIT 许可](yabai-MIT.txt)。手势字段技术亦参考该版本的 `space_manager.c`。这是内部接口研究，不构成生产兼容承诺。
