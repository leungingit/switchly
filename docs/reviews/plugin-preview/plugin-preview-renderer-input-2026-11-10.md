# 真实共享 Renderer 的后台输入与捕获对照

日期：2026-11-10。接续 [第一轮合成实验](plugin-preview-background-input-2026-11-10.md)。本轮仅在系统临时目录构建实验候选，不改变正式预览契约或运行代码。

## BG-D05：真实 2D 预览动作会话的后台输入通过

从当前 `project.yml` 读取预览 target 的 98 个 Swift 源文件，直接编译仓库共享 Renderer；只把 `PreviewAppMain.swift` 的实验版本放在系统临时目录。候选复用已有预览 App 的资源、GLTFKit2 framework 和已构建 worker。未重新实现 `PluginSlotSurface`、`PluginOverlayView`、SceneKit 组件或 JS runtime；未重新编译 worker，结果覆盖该现有二进制与当前候选组合。

候选在 accessory、不主动激活、不 makeKey 的窗口中，使用观察 `PluginPreviewState` 的小型壳展示共享 `PluginSlotSurface`，回调进入原 `perform → session.action → worker JS → updateRender`。与正式工作台壳、正式后台无交互窗口策略存在差异，不能把候选称为正式 `run --background` 已修复。

使用仓库 `Tests/PluginPreview/Fixtures/native-input` 的真实 JS 与原 7 步场景：

| 通道 | 输入结果 | 动作后的状态 | 截图／报告 |
| --- | --- | --- | --- |
| 原进程内驱动，无外部 AX | `Go` 为 `element-not-found` | 后续步骤 skipped | 报告 failed，符合原问题 |
| 外部只读 AX 后，原进程内 press | 7/7 passed | `last:none → last:go → last:mute` | 部分与屏幕相交的后台窗口中 passed |
| 外部 AX press | 7/7 passed | 同上，禁用 Stop 不改变动作 | 同上 |
| 外部 AX 取坐标，向指定窗口分派事件 | 7/7 passed | 同上 | 同上 |

读取 AX 不等于系统鼠标输入；坐标通道用目标窗口局部坐标构造 `NSEvent`，配合 AppKit 按钮跟踪先入队 mouse-up、再同步分派 mouse-down。它不向全局 tap 投递，也不直接调用业务 action。

AX 和坐标通道分别运行 4 个原有负向场景，8/8 得到预期失败详情：

```text
disabled-click → element-disabled
not-disabled   → element-not-disabled
missing        → element-not-found
wrong-action   → wrong-action-routed
```

负向组均记录 `front_changes=0`、`front_same=true`、`pointer_sample_changes=0`、`mouse_event_sources={}`。候选进程在失败报告时仍可能退出 0，因此本轮按 report.status 和 steps 判定，不把进程退出 0 当作断言通过。

## BG-D06：真实 3D 的几何点击通过，AX 语义命中缺失

只读外仓并把真实 `com.switchly.music-controls` 插件及原 GLB 复制到临时目录；开启 `ipod3d`，注入外仓 `media-playing.json` 合成 fixture。没有操作真实 Music、真实媒体桥或用户媒体数据。

- 外部 AX 能枚举窗口，但 `Play/Pause` 匹配数为 0，步骤失败 `element-not-found`。本轮不把它归为 AX 后台能力整体失败；当前 3D 命中没有通过此树暴露为可查找的按钮。
- 几何通道在真实 `PluginScene3DPointerView` 上扫描 SceneKit 命中结果，经已有 `Scene3DHitRouter` 找到声明的 `toggle` 命中点，再向窗口依次分派 mouse-down／mouse-up。没有调用 `pointerDown`、`pointerUp` 或插件 action 作为捷径。
- 实际命中点为视口 top-left 坐标 `(128, 360)`，视口 `300×480 pt`。场景的文本、`expectAction: toggle` 和后续文本共 3/3 passed。
- 部分与屏幕相交的后台窗口中，完整报告 passed、原生截图成功；主控实际查看前后 PNG：iPod 的暂停符号变为播放符号。最终 `ui-tree.json` 中 `play.fill` 为 2 处、`pause.fill` 为 0 处，证明合成媒体状态和共享表面输出已更新。

这属于通过 SceneKit 帮助寻找坐标的工程探针，不代表 Agent 已能从截图独立定位任意 3D 控件。未测试拖动、hover、滚动、键盘、文本输入或旋转后命中。

## BG-D07：本轮监测证据与输入来源边界

独立监测进程订阅应用激活通知，每 10 ms 采样指针位置，并通过只读 `CGEventTap` 记录 mouseMoved／mouseDragged 的事件来源 PID 与数量。未监听键盘、未保存输入文字、未截图其他应用。

部分与屏幕相交的后台窗口中，三条 2D 成功通道及 3D 几何成功组均有：

```text
front_changes=0
front_same=true
pointer_sample_changes=0
mouse_event_sources={}
```

实际完全在屏幕外的 3D 单次几何输入组也记录到以上结果；各输入步骤记录 `active=false key=false`。这是本机有限运行时段的无前台／指针变化证据，不保证所有应用、系统或长时间并发任务均无干扰，也没有连续审计用户应用内部的焦点对象。

其他轮次出现来源 PID 为 0 的系统鼠标移动事件。未观察到目标／辅助进程 PID 作为移动来源，但 PID 0 不能直接等同于物理鼠标，不能无证据将全部变化归因于用户。本轮保留有变化的结果，未按成功组覆盖。

## BG-D08：修正“屏幕外截图通过”，完全屏幕外的捕获仍失败

**本条取代第一轮 BG-D02／BG-D03 及 PV-D07 中未经实际 frame 核验的“屏幕外截图通过”表述；后台输入和后台窗口截图的其他证据保留。**

普通标题窗口请求 `(-10000, -10000)` 后，系统会约束实际位置。本轮补记 frame，观察到：

```text
2D frame=(-360, -155, 400, 187) screen_overlap=true
3D frame=(-360, -556, 400, 588) screen_overlap=true
```

这些窗口仍有约 `40×32 pt` 与主屏相交，不能作为完全屏幕外或绝不露出的证据。仅看传入坐标、截图成功或 `SCWindow.isOnScreen` 都不足以判断。

候选随后使用仅用于实验的 `NSWindow` 子类，让 `constrainFrameRect(_:to:)` 返回原 frame，并核对所有 `NSScreen.frame` 与实际窗口 frame 不相交：

```text
2D frame=(-10000, -9555, 400, 187) screen_overlap=false
3D frame=(-10000, -9956, 400, 588) screen_overlap=false
```

此时 2D 的三条通道依旧各 7/7 passed，3D 几何输入依旧 3/3 passed；但 `screencapture -l` 前后捕获均退出 1，报 `could not create image from window`。整体结果为 environment-error，不能宣称视觉闭环通过。

进一步按仓库 `ThumbnailService.performSCKCapture` 已使用的 API 形态，独立测试 `SCContentFilter(desktopIndependentWindow:)` 和 `SCScreenshotManager.captureImage`。完全屏幕外的 2D／3D 窗口均可被列出，但捕获返回：

```text
sck_target_windows=1
sck_capture=FAIL SCStreamErrorDomain Code=-3811
Failed to start stream due to audio/video capture failure
target_alive_on_capture_return=True
```

为排除窗口提前关闭，两组都延长为 60 次真实原生输入，60/60 passed，并确认捕获错误返回时目标进程仍存活。SCWindow 的 `isOnScreen` 仍可能为 true，与实际屏幕几何不相交并存，不能据此推断画面可捕获。

同一 ScreenCaptureKit 辅助程序的屏幕内后台 2D 对照成功：`sck_capture=PASS size=800x310`，捕获返回时目标仍存活，60/60 输入步骤通过；主控实际查看 PNG，`last:go`、播放按钮、灰色 Stop 与开关完整。该对照排除了辅助程序在当前环境完全不可用的情况，仍不足以定位系统内部捕获失败的根因。

ScreenCaptureKit 的首个辅助程序曾因未初始化 AppKit 报 CGS 初始化断言；修正为初始化 accessory `NSApplication` 后，才取得上述 -3811 结果。早期临时 fixture 相对路径错误、截图文件预先写入报告目录导致空目录门禁拒绝等探针错误均已修正，不当作产品缺陷或通过证据。

## 验证范围与下一步

- 本机 arm64、macOS 27.2；候选真实编译成功，使用当前安装的 Swift 工具链。直接编译出现现有 API 弃用警告，未为实验修改共享源码。
- 主控已查看成功组的 2D 和 3D 窗口 PNG；完全屏幕外失败组没有可看的捕获产物，明确未通过。
- 运行共享源码守卫，实际输出：`共享源码守卫通过：33 个核心类型各一处定义，预览 target 编译宿主源码`。
- 不修改正式 Swift 源码／构建配置／公开契约，不签名、不安装候选、不重启正式 Switchly；未运行宿主全量 build／unit test，因仓库变更仅为实验记录。
- 运行产物和辅助程序均在系统临时目录；保留本报告关键输出后清理。此轮未交付可重复运行的正式探针工具。

问题 → 方案 → 后续：真实后台输入已取得证据，但完全屏幕外的 WindowServer 捕获未通过 → 下一轮应验证保留可捕获原生表面的隔离环境，或共享原生视图的其他捕获方式 → 捕获、真实 3D 交互和无干扰证据同时通过后，才设计正式输入协议。3D AX 暴露、macOS 12 降级、完整鼠标／键盘和真实 Dock 系统行为仍待验证，PV-T02 原生输入隔离不放行。
