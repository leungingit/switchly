# 空闲截图开销排查记录

## D01 — 移除监控驱动的常驻截图预热（2026-10-22）

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
