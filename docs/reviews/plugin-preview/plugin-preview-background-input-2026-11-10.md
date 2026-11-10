# 插件预览后台输入的小范围对照实验

日期：2026-11-10。范围：独立合成 SwiftUI／AppKit 窗口；不修改预览 App 的启动、输入或发布契约。

后续修正：本记录没有保存窗口实际 frame，不能凭请求的屏幕外坐标确认窗口完全移出显示器。关于“屏幕外截图通过”的表述被 [第二轮 BG-D08](plugin-preview-renderer-input-2026-11-10.md#bg-d08修正屏幕外截图通过完全屏幕外的捕获仍失败) 取代；原后台输入和截图现象保留，完全屏幕外视觉验收未通过。

## BG-D01：后台 AX 输入在合成界面可行

同一未激活、非 key 的后台窗口，直接复用仓库 `PluginPreviewNativeDriver.swift` 时，SwiftUI 按钮、禁用按钮和开关均为 `notFound`。另一个进程通过 `AXUIElementCreateApplication(pid)` 和 `AXUIElementCopyAttributeValue` 遍历系统 AX 树，可以发现这些控件；执行 `AXUIElementPerformAction(..., kAXPressAction)` 后，按钮回调和开关状态真实变化。

这为原有 PV-D05 的后台节点缺失提供了新的对照：原进程内枚举失败不能作为后台交互不可行的依据。尚未解释 SwiftUI 内部机制，尚未在共享插件 Renderer 或正式预览会话中复现。

## BG-D02：外部只读 AX 遍历会改变本例的进程内枚举结果

每组实验启动新进程，固定 accessory 策略，不激活、不 makeKey，使用相同合成内容。先等待 500 ms，进入实验后等待 300 ms，执行原驱动；再等待 800 ms 重试，仍为 `notFound`。

| 对照 | 外部操作 | 随后原驱动结果 | 实际按钮回调 |
| --- | --- | --- | --- |
| 不访问外部 AX | 无 | `notFound` | 0 |
| 外部只读 | 读取系统 AX 树，不执行动作 | `pressed` | +1 |
| 外部读取并 press | 读取后执行 AX 动作 | `pressed` | 原驱动另增 +1 |

上述三组分别在屏幕内后置窗口、从启动起位于屏幕外的窗口运行，六组退出码均为 0。屏幕外坐标为 `(-10000, -10000)`；窗口仍 `orderBack`，并非 `orderOut` 或无 WindowServer。该对照支持“系统 AX 访问触发了本例可访问性状态变化”的推断，不能断言稳定的初始化协议，也不应把外部读树包装为无条件有效的修复。

AppKit 对照按钮在原驱动中始终 `notFound`，外部 AX 与窗口事件可以操作它。该现象未单独定位，不将它与 SwiftUI 节点初始化归为同一根因。

## BG-D03：指定窗口坐标事件可操作本例后台控件

构造指定 `windowNumber`、窗口局部坐标的 `NSEvent.mouseEvent`。为配合 AppKit 同步按钮跟踪，先向本 App 事件队列放入 mouse-up，再将 mouse-down 交给 `window.sendEvent`；不是向全局事件 tap 投递。未直接调用按钮业务 action，也未调用 `performClick`。

不经过外部 AX 初始化的独立组中，窗口事件结果：

```text
after_ax_inprocess outcome=notFound count_delta=0
window_event target=swift_button count_delta=1 disabled_delta=0 toggle_changed=false
window_event target=swift_disabled count_delta=0 disabled_delta=0 toggle_changed=false
window_event target=swift_toggle count_delta=0 disabled_delta=0 toggle_changed=true
window_event appkit_delta=1
window_capture_status=0
```

屏幕内和屏幕外均观察到同样行为。屏幕外最终补充组：

```text
window_final active=false key=false became_key_events=0
SUMMARY front_changes=0 front_same=true pointer_changed_samples=123 pointer_final_same=false
```

这只证明受控预览进程内的指定窗口输入可行，不等同于系统鼠标点击、跨进程事件隔离或完整鼠标输入模型。未测试 `CGEvent.postToPid`、hover、拖动、滚动、键盘、文本组合输入、菜单、弹窗或 3D 命中。

## BG-D04：返回成功与禁用保护必须分别验收

外部 AX 对禁用按钮的 press 返回 `AXError.success`，但 `AXEnabled=false`，实际禁用按钮回调计数始终为 0。不能仅用 AX 返回值判断按钮被触发。正式接入必须保留 enabled 检查，并验证实际动作路由和界面状态。

外部动作组的原始关键输出：

```text
external_nodes=10
external_press label=SwiftUI Probe Button matches=1 enabled=Optional(1) read=0 result=0
external_press label=SwiftUI Disabled matches=1 enabled=Optional(0) read=0 result=0
external_press label=SwiftUI Probe Toggle matches=1 enabled=Optional(1) read=0 result=0
external_press label=AppKit Probe Button matches=1 enabled=Optional(1) read=0 result=0
after_external swift_count=1 toggle=true native_count=1 disabled_count=0
```

## 环境、执行与证据边界

- 本机 arm64；`Version 27.2 (Build 26B123)`；Apple Swift 6.4.2；GUI 会话；已有 Accessibility 和 Screen Recording 授权，未申请新权限。
- 临时探针复用仓库原驱动源码，编译命令为 `xcrun swiftc -parse-as-library "$PROBE_ROOT/Probe.swift" Tools/PluginPreview/UI/PluginPreviewNativeDriver.swift -o "$PROBE_ROOT/probe"`。`PROBE_ROOT` 是系统临时目录中的本次任务目录；不修改仓库 Swift 源码。
- Python `subprocess.run` 驱动各组，单组超时 20 秒。最初探索轮已打印汇总，但 `NSApp.stop` 后没有退出，最终被超时结束；此轮不计为通过。改为清理窗口／观察者后显式退出，后续正常结束。
- 正式对照为六组（后置／屏幕外 × 不读 AX／只读 AX／AX press）；另补两组屏幕外事件／AX 动作，加入窗口成为 key 的通知记录，均退出 0，`became_key_events=0`。
- 通过 `NSWorkspace.didActivateApplicationNotification` 记录前台应用切换，正式六组及补充两组均为 `front_changes=0`、`front_same=true`。
- 每 10 ms 采样指针位置，并在部分动作调用前后比较位置。屏幕内 AX press 组出现完整轮次 `pointer_changed_samples=0 pointer_final_same=true`；其他多轮存在指针变化，个别同步调用前后也不同。未收集输入事件来源，无法区分用户移动与探针影响，不能把所有组标为“指针零干扰通过”，也不能擅自归因于用户。
- 以 `/usr/sbin/screencapture -x -o -l <本探针窗口 ID> <PNG>` 捕获自己的合成窗口；正式各组退出 0。实际查看屏幕内和屏幕外截图，确认 SwiftUI 按钮、灰色禁用按钮、开关、计数文字与 AppKit 对照按钮完整；屏幕外事件组显示 `count=1 toggle=true`，AX press 加后续事件组显示 `count=3 toggle=false`。
- `cacheDisplay` 的探索性截图遗漏了底部 AppKit 内容，未用于完整视觉验收；以上视觉结论来自实际窗口捕获。
- 不读取用户窗口内容，不记录窗口标题、前台应用名称或键盘输入。临时源码、可执行文件、PNG 和日志在结论摘录后清理；本报告保留关键输出。未保留可直接重跑的正式探针工具。

## 后续与状态

1. **已完成**：合成界面的外部 AX、进程内原驱动、指定窗口事件对照；后台／屏幕外截图核验。
2. **待验证**：把同一对照应用到真实共享 Renderer 和预览动作会话，验证标签歧义、禁用和错误路由；保留现有 `nativeClick` 证据含义。
3. **待验证**：独立记录指针事件来源与输入影响，补充真实 3D 命中、hover、拖动及键盘路径；连续焦点监测不能由运行前后采样替代。
4. **未放行**：正式 `run --background` 原生交互、完整零干扰承诺、PV-T02 的原生输入隔离与 PV-T03。本次不改变契约，也不声称复现了 ChatGPT 的内部实现。

问题 → 方案 → 后续：进程内后台节点缺失 → 优先验证外部系统 AX 和指定窗口输入 → 先接真实共享 Renderer 做第二轮探针，再决定生产输入通道；独立 GUI runner 保留为完整桌面验证路线。
