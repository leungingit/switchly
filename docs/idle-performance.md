# 空闲截图开销排查记录

## D01 — 移除监控驱动的常驻截图预热（2026-10-22，被 D02 部分取代）

**现象与边界**：用户报告未使用预览（包括 Dock 预览）时 GPU 占用偏高。本次修复消除已定位的空闲截图路径；尚无 GPU 硬件计数器的前后对照，不能据此认定已解释全部 GPU 占用。

**代码依据**：原 `WindowMonitorService.processWindowChanges` 在启动、应用激活/启动/退出及每 1/2/5 秒轮询时枚举屏幕窗口，并选择变化窗口、前台应用或受监控应用的窗口（每轮最多 8 个）调用 `preheatThumbnails`。该路径不检查面板可见性。`claimPreheat` 只检查正在捕获、失败冷却和缓存年龄，缓存约 45 秒后可再次截图；新窗口、标题或几何变化也会触发候选更新。因此 `runRefreshTick` 的可见窗口 interest 限制无法阻止此独立预热路径。

**结论**：窗口监控只发出刷新通知。已有 Preview / Dock / Workspace 消费方各自以可见性决定是否枚举；打开面板时继续按需读取缓存和截图，原有磁盘旧图恢复、去重、失败退避与可见面板刷新保持原路径。删除仅为预热服务的窗口快照、应用标识、排序和预算。

**可检查约束与证据**：

- `make generate`：成功；XcodeGen 仅为新增测试更新工程索引。
- `make build`：退出码 0，输出 `Build complete!`。
- `make test-unit`：266 项测试，4 项跳过，0 失败，`TEST SUCCEEDED`。
- `WindowMonitorIdleTests.testIdleMonitorNotifiesWithoutEnumeratingOrPreheatingWindows`：启动和连续 101 次轮询/应用事件入口调用通知后，枚举次数为 0。
- `WindowMonitorIdleTests.testIdleTimerStillNotifiesVisibleConsumersWithoutEnumerating`：真实 1 秒计时器发出通知，枚举次数仍为 0；使用有界异步 expectation，不使用固定 sleep 或嵌套 RunLoop。
- `./verify.sh`：0 失败、2 警告（未提交改动、已有超过 500 行文件）。

**真实运行补充**：退出旧 `build/Switchly.app` 后，启动 `DerivedData/Build/Products/Debug/Switchly.app`（PID 8296）。执行 `sample 8296 55 10 -file <系统临时目录>/idle.sample`，在每 10 毫秒一次、持续约 55 秒的采样中，`captureAndCache`、`CGWindowListCreateImage`、`SCScreenshotManager` 符号匹配均为 0；采到监控通知路径。采样可能漏掉短调用，只作为空闲路径的辅助证据，不等同于截图计数器或 GPU 硬件计量。原始采样含机器环境信息，仅在系统临时目录分析，交付前清理，不上传。

**影响面与未验项**：没有缓存的首次预览需等按需截图，不再通过常驻截图提前填充。没有新增设置、依赖、权限或网络能力。GPU 百分比下降幅度、首次打开面板的实际延迟和真实 Dock 悬停交互尚未完成对照验收；本记录不以单元测试替代这些系统行为。

## D02 — 监控预热改为“只补无缓存窗口”（2026-10-23，部分取代 D01）

**裁决**：D01 整体移除预热过头了——没有缓存的窗口首次打开预览会等现拍。预热要保留，但窗口已有缓存截图时不再预热。

**实现**：`WindowMonitorService.processWindowChanges` 重新枚举屏幕窗口，先用 `getCachedThumbnail` 过滤掉有内存缓存的窗口，剩余按“前台应用 > 受监控应用 > 有标题”排序，每轮最多 8 个交给 `ThumbnailService.preheatUncachedThumbnails`。后者再过滤近期失败的窗口，对其余窗口先尝试 `restoreCachedThumbnail` 恢复磁盘旧图，恢复失败才调用 `preheatThumbnails` 截图。已缓存窗口的刷新仍只由可见面板的 refresh interest 驱动。

**取舍**：不再按窗口标题/几何变化触发重拍（D01 前的 `WindowSnapshot` 已删除），变化窗口的新鲜度交给可见面板的定时刷新；缓存超过 45 秒不会被监控重拍。`getOnScreenWindows` 每轮监控仍会执行，但不触发截图。

**证据**：`make build` 成功；`make test-unit` 268 项、4 跳过、0 失败。`WindowMonitorIdleTests` 覆盖：仅无缓存窗口被预热、全部有缓存时 51 次监控入口调用零预热、单轮上限 8、仍发出刷新通知。

**未验项**：未做空闲 GPU 占用前后对照，也未实机验证“稳态下确实不再截图”（需看日志中 `Preheating thumbnails. reason=timer` 在缓存齐全后不再出现）。

## D03 — 周期性刷新重复发布导致面板重复重绘（2026-11-02）

**现象**：Dock 预览面板一直打开时每 2~3 秒闪白一次，像重新渲染或重新截图。

**代码依据**：`WindowMonitorService` 默认 `balanced` 每 2 秒重扫窗口并发 `.windowListDidRefresh`。`DockPreviewViewModel.refreshWindows` 对 `windows` / `selectedWindow` / `panelWidth` / `panelHeight` / `isEnumeratingWindows` 无条件赋值，而 `@Published` 对同值赋值同样发布；`panelWidth`、`panelHeight` 的发布驱动 `DockPreviewPanel.observePanelWidth`，每 2 秒执行一次 `Motion.movePanel(... setFrame(display: true))`，透明玻璃面板被周期性强制重绘。`WorkspaceBarPanel` 是同一类缺陷：`refreshItems()` 无条件 `items = nextItems`，`$items` 的订阅方对同一 frame 重复做 morph。

**结论**：发布前先比较内容，尺寸/位置未变则不重设。`WindowInfo.==` 只比 id，必须逐字段比较（标题、几何、桌面归属、最小化/隐藏）。

- Dock 预览：`DockPreviewViewModel.refreshWindows` 逐字段比较 `windows`，其余属性仅在变化时赋值；抽出 `setPanelSize` 只在尺寸真实变化时发布。PR #23。
- Workspace 栏：`refreshItems` 逐字段比较 `items`（`itemsEquivalent`），空工作区也不再重复发布；`positionInCurrentScreen` 增加 frame 近似相等则跳过重定位。本记录同批提交。

**证据**：

- `DockPreviewRefreshTests`：同一窗口快照重复刷新，旧实现 5 次发布（正好 5 个 `@Published`），新实现 0 次；标题变化仍更新。
- `DockPreviewPanelRefreshTests`：真实 `DockPreviewPanel` 可见时 3 次刷新，旧实现 67 次 `setFrame`（动画帧），新实现 0 次；窗口消失仍重新布局。测试先等入场动画静默 0.3 秒再计数，避免把动画帧算进去。
- `WorkspaceBarRefreshTests`：同一快照重复刷新，旧实现 1 次发布，新实现 0 次；空工作区同样不再重复发布。
- `make build` 成功；`make test-unit` 543 项、8 跳过、0 失败。
- 真实悬停取证：修复后的 Debug 构建在 Dock 预览打开状态下连拍 10 帧（约 7 秒，覆盖 3 个刷新周期），面板区域逐帧像素差全为 0。闪白本身持续时间短，0.7 秒间隔的连拍未直接截到闪白帧，旧实现下的帧差经裁剪核对来自玻璃后方窗口内容滚动，因此该组截图只作为辅助证据。

**影响面与未验项**：仅减少重复发布与重复定位，不改变窗口匹配、缓存或截图路径。Workspace 栏的 frame 跳过重定位没有独立单测（`positionInCurrentScreen` 为私有且 `show` 会激活应用），需要真实快捷键唤起核对。

## D04 — 待办：两个 20 Hz 常驻轮询（未实施）

`DockHoverMonitor` 与 `PreviewTriggerMonitor` 各自以 0.05 秒间隔常驻 `Timer`，且未设置 `tolerance`；两者都另有全局 `mouseMoved` 监听。轮询真正必要的场景只有两处：Dock 自动隐藏时图标尚未识别出来需要重试 AX；面板被 Escape/点击等外部路径关闭后需要检测 desync。其余时刻鼠标移动事件已覆盖。实测空闲 CPU（Debug 构建）约 0.6%~0.8%，采样中主线程绝大多数时间阻塞在 `mach_msg`，未见截图路径。

**建议**：给定时器设置 `tolerance`，或改为只在“面板可见 / 指针在 Dock 带或热点区”时启动。改动涉及自动隐藏与 desync 检测，需要真实 Dock 悬停回归，暂未实施。

## D05 — 待办：插件渲染循环（未实施）

`DockPluginOverlayModel` 在 Dock 面板可见时按插件 `refreshInterval` 循环渲染，内置三个插件分别声明 1s / 1s / 2s（`../switchly-plugins/plugins/*/manifest.json`），即每秒 3 次 JS 渲染。`render` 已用 `merged != slots` 避免无谓发布，但 JS 本身照跑。若插件内容不依赖时间，可改为输入变化才渲染；需要插件侧先明确时间依赖，暂未实施。

## D06 — 待办：缩略图自动刷新跳过不可见窗口（未实施）

`ThumbnailService` 每 8 秒对“可见面板声明感兴趣的窗口”重截图，面板隐藏即 `clearRefreshInterest`，属于实时预览的固有成本。最小化与其他桌面的窗口仍会进入截图队列并走失败冷却，可提前跳过以减少无效截图。收益有限，暂未实施。
