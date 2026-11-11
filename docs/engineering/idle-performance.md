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

## D07 — 音乐组合桥回退复用同批采样（2026-11-11）

**问题与实测**：正常音乐组合桥在 MediaRemote 尚无候选时，先执行两次 `nowPlaying`，随后 `frozenRead` 又执行两次，发布前再校验一次，共五次串行 AppleScript 状态读取。本机真实 Music、Debug 构建的独立媒体探针，六次读取加最终校验：首次 875 ms，后五次 547–566 ms；已有配对候选时为三次，六次 316–342 ms。这是媒体链路耗时，不是鼠标悬停到屏幕首帧。

**契约与方案**：复用同批次刚读取的 Music 样本作为封面读取的前置样本；没有系统候选时跳过专为配对执行的第二次读取，配对失败时复用第二个样本进入回退。回退仍在读取封面后重新采样，切歌时拒绝图片；发布前仍独立复核歌曲、喜欢和播放状态，保留来源代际、进程身份与整组回退规则。不得使用跨批次过期快照提速，不放宽封面校验。

**验证约束**：无候选时含最终校验三次状态读取；候选不匹配时四次；配对成功时三次。覆盖封面读取期间切歌、来源变化与最终校验期间状态变化。

**启动通知合并**：媒体流启动与首批封面会触发失效通知。通知到达时，正在执行的异步读取可能尚未固定采样代际；若无条件提升渲染 revision，会连该读取随后取得的最新有效批次也丢弃，再支付整批读取成本。通知仍立即撤销已失效的旧图并请求刷新；在途批次能否发布由最终 `mediaReadIsCurrent` 与同步 `isFresh` 决定。目标切换、停止和动作继续提升 revision。回归必须证明：通知后取得的有效首批可直接发布，过期批次仍不能发布。

**复测结果**：Apple M4 Pro、macOS 27.2、Debug、真实 Music 暂停态。媒体探针直接调用实际组合桥和 `isCurrent()`；面板探针注入实际组合桥和相同音乐插件制品，调用真实 `DockPreviewPanel.show`，每次关闭后间隔 500 ms，再次打开。用 10 ms 主 RunLoop timer 记录最长调度间隔。面板指标止于插件 `slots` 提交，不是屏幕首帧，也不包含 Dock 悬停触发延时。

| 指标 | 修改前 | 修改后 |
| --- | --- | --- |
| 无系统候选：媒体读取加最终校验，首次后的 5 次 | 547–566 ms | 333–358 ms |
| 已有配对候选：媒体读取加最终校验，6 次 | 316–342 ms | 311–350 ms |
| 3D 浅色：重复打开到插件内容提交，2 次 | 549、528 ms | 337、347 ms |
| 3D 浅色：进程首次打开到插件内容提交，1 次 | 1130 ms | 672 ms |
| 3D 浅色：首次打开最长主线程调度间隔，1 次 | 451 ms | 271 ms |

无候选路径的热样本中位数约从 559 ms 降至 334 ms（约 40%）；3D 浅色重复打开均值约从 539 ms 降至 342 ms（约 37%）。这是小样本本机对照，不是 p95、发行性能承诺或用户体验验收。首次数据包含 SwiftUI／SceneKit 初始化及系统缓存差异，不以单次比值宣称普遍收益。深色复核：2D 重复打开 358／355 ms，3D 为 334／345 ms。

**构建与测试证据**：第一处修复在原工作区 `make build` 成功，`make test-unit` 为 808 项、9 跳过、0 失败；随后原工作区并行进行的插件锁迁移出现 `插件准备失败：外仓制品与锁文件不符：com.switchly.music-controls`。未修改该锁或绕过门禁。将 HEAD 源码与本轮三个实现文件、两个测试文件及本记录复制到系统临时隔离副本；制品副本与 HEAD 原锁逐文件核对，三个插件全部相符。在该副本执行：

```sh
SWITCHLY_PLUGIN_SOURCE=/tmp/switchly-dock-perf.79UTyb/plugins make build
SWITCHLY_PLUGIN_SOURCE=/tmp/switchly-dock-perf.79UTyb/plugins make test-unit
```

输出：`Build complete!`；`Executed 809 tests, with 9 tests skipped and 0 failures`；`TEST SUCCEEDED`。原工作区 `./verify.sh`：`PASS 0 check(s) failed, 2 warning(s)`（未提交修改、已有超长源文件）；`git diff --check` 退出 0。没有把原工作区最后一次普通构建报告为通过。

五项新增回归覆盖：无候选的采样次数及发布前切歌、候选不匹配的采样复用、封面读取期间切歌拒图、配对后播放状态变化拒绝发布、媒体通知到达后的有效首批不依赖重读即可提交。既有过期媒体批次原子发布、浏览器抢占、停止／重启、3D 生命周期测试继续通过。实际查看了 ScreenCaptureKit 对真实面板采集的 3D 浅色、3D 深色及 2D 深色截图：曲目信息、封面和暂停态播放图标均有显示；首次使用 `cacheDisplay` 的 3D 图缺少 SceneKit 图层，已判为无效证据并改用系统合成截图。

**剩余问题与后续**：首次初始化仍存在约 271 ms 的主线程长间隔，3D 重复打开的最长间隔约 29–40 ms，不能宣称已消除全部卡顿。采样包含 SwiftUI 布局、SceneKit 初始化及同步 surface 栅格化；没有证据将全部停顿归因于 GLB 重载。后续需单独量化初始化与表面刷新阶段，再决定预备或复用方案。本轮未进行真实鼠标悬停全链路计时、播放中压力／快速切歌视觉验收、GPU 硬件计量、Intel／macOS 12 验证；没有重启或替换用户当前运行实例。临时探针、截图、日志和隔离副本在交付前清理，仅保留以上脱敏测量记录。

## D08 — Dock 快速切换与插件并行准备（2026-11-11）

**范围**：用户授权优化音乐并行加载，并排查普通 Dock 图标快速移动时的整体性能。保留 D07 修复、既有视觉、窗口归属及媒体一致性规则；不通过降低悬停延时、停用材质或关掉校验掩盖瓶颈。

**实施契约**：插件可选 `prepare(ctx)` 返回不依赖实时媒体的初始 UI，使用与 `render` 相同的解码／预算。与媒体读取并行，只允许在当前目标尚未提交正式批次时发布；初始界面没有媒体封面、实时状态与可执行动作，正式批次验证后原子替换。缺少 prepare 的插件保持旧行为。关闭、切换目标、撤权后不得发布迟到的初始界面。音乐插件在外仓实现数据无关的加载界面，使模型加载和面板布局在媒体返回前启动。

**普通预览排查**：检查同图标悬停计时器重置、AX 热路径、窗口列表的重复系统查询及同一目标的重复面板动画。仅将已定位的独立工作并行化或复用，保留 AX 超时、跨桌面归属和取消语义。每项修复须有回归或真实系统探针证据；最终记录前后时延、主线程停顿、截图与未验项。

**已实施**：

- `DockHoverMonitor` 同一产品内移动不再重置悬停计时。全局事件与轮询共用最新位置缓冲，一批积压位置只处理最后一个，停止时清空。
- Dock AX 遍历改为单一后台查询，主线程用有效缓存立即匹配；保留 0.12 秒有效期及原 AX 超时。最多一个查询在途，停止／设置变化后拒绝迟到结果；完成后将当前指针位置重新送入合并入口，不额外等下一次轮询。
- 窗口查询先按目标产品筛选，再做同步去重；按窗口快照的唯一 PID 解析归属，保留嵌套及辅助进程。缓存中的窗口若已在屏幕快照中，提前排除，避免无候选时仍读取完整 CG 列表和 Spaces 信息。
- 应用解析先匹配产品路径或名称，再查询匹配进程的动态 activationPolicy，避免每次悬停都查询所有进程动态状态；匹配规则未变。
- 插件包发现、校验和运行时构造走 Host 专用加载队列。取消／切目标后不恢复迟到的运行时。可选 prepare 与媒体读取同时进行，正式界面先提交时忽略迟到准备结果；准备态禁用命中与动作路由。
- 音乐外仓共享同一个卡片构造函数生成加载态和正式态，覆盖普通二维卡片、转盘与 3D。同插件／目录／asset 的在途模型解码继续使用，完成后组装最新表面，避免从加载态切到正式状态时取消重读。
- 面板按发布出来的尺寸合并布局，同一目标 frame 不重复发起 morph；隐藏或更新目标后，旧的待显示任务失效。设置和可见状态未变时不重复发布。

**实测与口径**：Apple M4 Pro、macOS 27.2、Debug，解锁状态下使用真实窗口服务、Dock AX 与原生面板；音乐单独启用音乐包，Music 暂停态。窗口查询各 8 次，中位数如下，前后返回窗口数量一致。

| 产品 | 本轮修改前 | 最终实现 | 窗口数 |
| --- | --- | --- | --- |
| Finder | 15.08 ms | 5.06 ms | 1 |
| Chrome | 14.86 ms | 3.29 ms | 2 |
| Code | 14.54 ms | 8.70 ms | 4 |
| Music | 14.13 ms | 2.24 ms | 1 |

真实 Dock 的 19 个图标，4 轮后台查询完成时间为 36.07／7.79／8.34／10.29 ms；主线程提交查询仅用 0.81／0.026／0.051／0.088 ms，缓存命中最长约 0.013 ms。该指标不是鼠标悬停到上屏时间。

音乐浅色重复打开 3 次：初始 slots 为 22.62／37.78／26.32 ms，SCNView 挂载场景为 45.72／59.12／45.95 ms，正式媒体批次提交为 323.64／322.45／331.67 ms；进程首次对应 141.43／191.95／501.49 ms。挂载不等于 GPU 首帧；面板入场仍有原有动画。独立的加载态视觉夹具将首次媒体读取挂起 1.5 秒，实际截图确认 Loading 占位和模型可先出现；此夹具不计入性能数据。

普通 Finder→Chrome→Code 连续 24 次切换，间隔 80 ms；排除前 3 次后的 21 次 show 调用，中位 18.39 ms、最大 52.24 ms。先期采样中位 32.91 ms；采样栈确认其中仍有重复缓存查询及全进程动态属性读取，最终两处提前筛选后下降。32.91 ms 是本轮中间实现，不冒充原始版本端到端基线。最终 10 ms 主线程采样的热阶段最长间隔 72.61 ms、前三次 163.36 ms；仍有系统布局及首次初始化成本，不能宣称已消除全部卡顿，也不作为 p95 或发行性能承诺。

**门禁与看图**：

- 外仓 `npm test`：47 通过、0 失败；`npm run build` 两条发行线成功，冻结的 v1 源码未改。显式 `make update-plugin-lock` 仅接受本轮新制品；外仓尚未提交，sourceRevision 为 null，不能用于发行。
- `make build`：`Build complete!`。`make test-unit`：`Executed 827 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`。
- SDK `npm test --prefix Plugins/sdk`：6 通过、1 跳过、0 失败。`make plugin-preview-build` App／Worker 均成功；`make plugin-preview-contract-check` 契约哈希、renderer revision 与共享源码检查通过。
- `Tests/PluginPreview/run-background-input-tests.sh ../switchly-plugins`：22 条 PASS，`SUMMARY background-input passed`；没有显示后台表面或发送全局输入来替代该验收。
- 实际查看真实面板的 3D 浅色／深色、2D 深色、普通 Code 四窗口和加载态截图，确认布局、封面及正式状态正确。测试仍保留窗口数量变化时真实宽高到达目标的断言。
- `./verify.sh`：0 失败、2 警告（已有大文件、未提交修改）；`git diff --check` 退出 0。

**环境裁决**：排查中 Mac 自动锁屏，导致 ScreenCaptureKit 报 -3811、后台表面不可用，NSWindow 动画代理也未执行。用户解锁后，原动画代理 frame 与 alpha 正常更新，后台输入回归通过。锁屏期间“系统动画入口失效”的假设撤回；`MotionTokens.swift` 及其原有测试未改，renderer revision 保持原值。原生动画回归增加锁屏检测，锁屏只能跳过并在解锁后复验，不能当作产品通过；最终上述 827 项是在解锁后运行的结果。

**交付状态与剩余项**：已通过 `make run` 启动当前 Debug app，路径为 `DerivedData/Build/Products/Debug/Switchly.app`（核对 PID 75331）；保留其他并行任务的修改，没有提交、推送或发布。真实全局鼠标输入、自动隐藏／放大 Dock 的完整组合、多显示器、Intel／macOS 12、播放中压力及 GPU 硬件指标尚未覆盖；本轮使用真实 AX 和原生面板连续切换探针，不将其表述为所有实机手势均已验收。首次初始化与长尾布局耗时仍需后续量化。临时探针、采样、截图和日志仅存系统任务临时目录，交付前清理。

## D09 — 首次加载、长尾与真实 Dock 输入（2026-11-11）

**范围与授权**：用户要求继续优化首次及长尾，并补真实鼠标快速划过、自动隐藏、放大场景。用户已明确允许以 CGEvent 仅发送全局鼠标移动、不点击或拖动图标，临时测试自动隐藏／放大组合，完成后恢复原设置。此授权仅用于本轮真实主 App 集成验证，不替代独立预览的后台隔离门禁。

**契约**：保留现有材质、系统动画、悬停延时与媒体整组校验。同步窗口查询不得等待 AX 去重；异步缺证据、失败或过期时保留候选窗口，只有输入快照、进程身份与 revision 一致的证据才能过滤。后台查询与待办均有边界，停止／换目标／换 Space 后丢弃过期结果。首次阶段按实际测量拆分后优化，不把热缓存或内部挂载冒充物理首帧。

**首次引擎预热约束**：实际冷启动采样观测到首个 PluginVM 阶段约 37 ms。将空 JavaScriptCore Context 的构造提前到悬停等待期间，在该插件自己的串行队列完成；此时不安装宿主桥接、不执行插件 JS、不创建 Timer、不获取媒体兴趣。当前可见调用消费同一个 Context 后才安装桥接和执行入口。只选择首个已启用匹配插件，预热调度最多一个任务及一个最新目标；卸载／重载使旧代际失效并清空 Context。其他插件、权限及正式 render 路径保持原规则。

**实测计划**：记录初始 Dock 键值与鼠标位置，以固定／自动隐藏 × 放大关／开四种组合，验证未打开时的快速掠过、停留触发、已打开时快速跨应用、移入面板及移出关闭。用实际运行的 Switchly、OS 鼠标事件、独立 CG／AX 观察和截图取证，记录命中、出现／关闭、时延与失败；恢复原设置后复核。

**已实施与复现依据**：

- 窗口浮层去重的 AX 查询移至独立串行队列。同步查询缺少有效证据时保留候选；异步结果回到主线程，逐组核对窗口签名、进程启动身份及枚举 revision 后才写缓存。每批最多 8 组、缓存最多 32 项，仅保留一个待处理的最新批次；相同签名在结果回主线程收尾前仍视为在途。失败不删除窗口，停止／换 Space 后拒绝旧结果。
- 真实放大 Dock 曾复现“系统命中 Music，但预览停留在 ego lite，面板与图标重叠约 24 pt”。生产路径改为在后台向 Dock 进程查询当前点的实际命中，避免放大动画中的旧矩形选中相邻图标；缓存只对同一指针位置有效。独立验收仍从系统级 AX 命中观察，未用产品自身判断代替验证。
- 指针停止后，在有界的布局稳定期继续刷新放大图标几何。同一产品只更新面板锚点，不重载窗口或重启悬停等待；锚点比较使用面板实际消费的中心及高度，忽略 AX 纵坐标和亚像素抖动，防止反复 morph。
- 自动隐藏 Dock 中，鼠标短暂离开后返回，旧“先触边”标记曾阻止仍然可见的图标触发。现在先刷新 Dock 外部设置，再判断几何区域，以 Dock 进程确认的可见图标命中决定是否触发；隐藏图标不能仅靠缓存几何触发。
- 空 JavaScriptCore 引擎按上文约束预热。3D 控制器在首次组装前接收宿主主题，避免先按默认浅色组装后立即重做；隐藏期间的主题变化在重新挂载保留场景前应用。没有更改现有材质、悬停延时或系统动画。

**真实输入结果**：Apple M4 Pro、macOS 27.2、Debug，最终运行实例 PID 46605，路径为 `DerivedData/Build/Products/Debug/Switchly.app`。CGEvent 只移动鼠标，未点击或拖动图标；系统级 AX 与 CG 窗口列表独立观察。最终四组在同一构建、1920×1080 外接显示器上完成，每组一次；快速掠过时均未出现中间目标面板，最终 Music 标题与系统命中一致，移入面板保持显示、移出后关闭均通过。

| Dock 组合 | 掠过后停留至 Music 标题可读 | 面板已开时跨应用至最终 Code 标题可读 | 面板与图标间距 |
| --- | --- | --- | --- |
| 固定、放大关 | 576.29 ms | 94.77 ms | 9 pt |
| 固定、放大开 | 579.98 ms | 211.17 ms | 2.67 pt |
| 自动隐藏、放大关 | 573.25 ms | 90.29 ms | 13 pt |
| 自动隐藏、放大开 | 732.04 ms | 204.77 ms | 2.67 pt |

计时从最终定位动作开始，到独立 AX 观察到目标标题可读为止；包含原有悬停等待、系统调度和观察成本，不是 GPU 首帧或媒体内容完成时间。放大场景为校准到实际系统命中最多移动三次，不把这一定位过程当成固定速度的人手轨迹；四个单次样本不能形成 p95 或普遍提速比例。自动隐藏揭示期间没有提前出现面板。最终离开关闭为 458–491 ms，保留既有关闭等待及动画。

**首次与长尾证据**：Instruments signpost 记录首次 `PluginVM` 为 37.13 ms；预热版本记录 `PluginEngineWarm` 35.42 ms、可见阶段 `PluginVM` 21.89 ms，前者提前到悬停等待期。后者还包含桥接及插件入口，不能将两次进程样本直接解释成端到端减少 15 ms。采集的这两份 signpost 没有完整 SceneKit／surface 阶段数据，因此本轮不报告 3D 冷启动屏幕首帧或主线程长尾改善比例。飞书预览另外保持 3.5 秒，89 个 CG 几何样本的宽、高范围均为 0，证明该段时间内面板尺寸稳定，不代表渲染线程没有停顿。

**门禁与实际看图**：

- 最终源码 `make build`：`Build complete!`；`make test-unit`：`Executed 841 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`。9 项跳过为需显式开启的视觉／媒体集成项目，最终窗口动画回归没有因锁屏跳过。构建有 CoreSimulator 版本不匹配提示，macOS 构建与测试成功；测试另有两条 QoS 等待告警，不能据此推断产品长尾已经消失。
- 新增回归覆盖点命中缓存不能跨位置复用、隐藏 Dock 不从旧几何生成命中、放大锚点只重定位不重载、后台去重失败保留窗口及旧签名拒绝发布、预热不执行插件代码、首次深色只组装一次及隐藏主题变化后重新挂载。
- `make plugin-preview-build` App／Worker 成功；最终 `Tests/PluginPreview/run-background-input-tests.sh ../switchly-plugins`：22 条 PASS、`SUMMARY background-input passed`。`make plugin-preview-contract-check`：契约哈希、renderer revision 一致，共享源码守卫 33 个核心类型通过。后台验证未显示表面，也未使用本轮全局移动授权替代隔离门禁。
- 实际查看最终系统合成截图：真实 Music 面板的封面、曲目信息、暂停态播放图标，以及四种组合中的 Code 四窗口布局。截图核验是本机观察，不代表用户最终视觉验收；D08 的 3D 深浅主题证据不冒充本轮全局鼠标测试的 3D 冷启动证据。
- 恢复并逐项比较 `autohide`、`magnification`、`tilesize`、`largesize`、`orientation`、`autohide-delay`、`autohide-time-modifier` 七个原始键值，续接会话再次读取仍完全一致；探针结束恢复原指针位置。`./verify.sh`：`PASS 0 check(s) failed, 2 warning(s)`（未提交修改、超长源文件）；`git diff --check` 通过。

**交付与后续**：本轮续接补齐证据整理和文档，保留已经通过验证的实现及并行任务修改；未提交、推送或发布。当前 Debug 实例已运行修复；完整冷启动／长尾分位数、3D GPU 首帧与硬件计量、跨显示器迁移／跨 Space、侧边 Dock、Intel／macOS 12、播放中压力和快速切歌仍未验收。D09 补充 D08 的真实鼠标和四组合证据，不覆盖这些剩余项。临时探针、截图、采样和日志在记录脱敏结论后清理。

## D10 — 3D 合成首帧、切歌与屏幕／Space 采样（2026-11-11）

**范围**：继续按采样优化首次及长尾，补真实播放中快速切歌、双屏及 Space 场景。保留 D09 的媒体整组校验、材质、动画与悬停等待；显式开启的验收入口复用实际媒体装配及音乐插件。系统合成帧只保存测试面板区域，时间口径区分 show、场景挂载、渲染回调、合成帧到达和正式媒体提交；渲染回调不能冒充屏幕首帧。命令、原始采样和截图仅放系统任务临时目录。普通测试不启动真实媒体或屏幕采集。

**采样与修复**：

1. 播放中连续切歌触发在途批次过期；代码审计发现，自动重试中若再收到通知，`renderRequested = allowRetry` 会把新请求覆盖成 false。新增 `testNotificationDuringRejectedRetrySchedulesLatestRead` 将周期刷新设为 60 秒，挂起第二次读取、插入通知，再拒绝该批次：旧实现停在两次读取、超时且计数断言失败；改为保留已有请求后，第三批立即读取并提交，定向回归通过。仅在没有新请求时限制自动重试，不放宽过期或封面校验。
2. 主线程采样确实进入 `PluginScene3DAssembly.bindSurfaces → PluginSurfaceRenderer.texture → CoreGraphicsPluginSurfaceRasterizer`。原实现即使贴图缓存命中，仍逐表面复制几何并重新合成底图；封面 token 也会使没有 artwork 节点的静态背板失效。现在复用节点的已应用像素签名，未变表面跳过几何复制与材质合成；仅向使用 artwork 的表面传入封面。签名随实例释放、主题重组装重新建立。新增回归证明封面变化不再重新栅格化静态表面；既有播放符号、主题、画面更新和生命周期测试继续通过。
3. 主线程聚合栈中的窗口刷新为 133 个样本，其中产品查找的 filter 为 81 个；3D 装配为 91 个样本。产品查找原来过滤所有进程再取首项，现在找到第一个匹配产品且为 regular 的进程便停止，保持原来的顺序、辅助进程归属和同名产品规则。后台 AX 枚举的 1453 个样本另计，不能当作主线程阻塞。

**3D 实测口径**：Apple M4 Pro、macOS 27.2、Debug；复用真实 Music 组合桥、实际插件包及 `DockPreviewPanel`，隐藏窗口缩略图。首次表示新测试进程内第一次 show，系统／驱动缓存未清空。用 10 ms 主 RunLoop timer 记录调度间隔，60 Hz ScreenCaptureKit 显示采集流在后台复制面板区域，最多保留 180 帧，结束后写盘并逐帧看图。流回调到达时间是包含合成及传递成本的可见性上界，不是显示器扫描输出或 GPU 硬件时间。首帧终点只要求模型出现，正式媒体可稍后替换 Loading。

| 指标 | 首轮样本 | 最终版本样本 |
| --- | --- | --- |
| 新进程首次场景挂载 | 761.28 ms | 588.89 ms |
| 首次 didRender 回调 | 796.87 ms | 628.28 ms |
| 合成流首次观察到 3D 模型 | 896.37 ms（frame 15） | 741.65 ms（frame 13） |
| 首次 3 秒内最长主线程调度间隔 | 442.89 ms | 231.02 ms |
| 最终版本重复打开两次：挂载／didRender | — | 58.60／71.46 ms；113.12／124.53 ms |
| 最终版本重复打开两次：最长主线程间隔 | — | 55.21 ms；90.77 ms |

首轮 frame 14（888.94 ms）尚无模型，frame 15 已出现；最终 frame 12（645.16 ms）尚无模型，frame 13 已出现。最终第二次打开在约 106.63 ms 的帧已能看到模型，仍有原入场淡入；第三次没有合成帧数据，因为前两轮已到 180 帧上限，不能拿挂载回调代替。中间另一新进程样本曾测到挂载 1634.31 ms、didRender 1892.93 ms、最长调度间隔 1323.33 ms，说明环境与首次初始化长尾仍大。以上小样本、不同媒体状态和系统负载不支持提速百分比、p95 或“全部恢复丝滑”的结论。调用栈与修复证明减少了明确的重复工作，尚不能把首轮／最终的全部差值归因于补丁。

**播放中快速切歌**：用原生 Music 控件连续发送六次 Next，首轮输入 1.20 秒，修复后 1.22 秒。播放器合并／延迟了部分命令，不把六次输入写成六个已完成曲目。在 200 ms 采样中，修复后先观察到多个真实候选变化，最后一个候选出现后约 0.83 秒提交对应曲目与封面；从六次输入结束到最终整批稳定约 2.88 秒，其中播放器最后候选本身在输入结束约 2.05 秒后才到达。此为一次序列，不能报告切歌 p95。首轮 349 个、后续 1660 个状态样本中，非空封面 token 分别涉及 2／11 个，每个 token 只对应一个已提交标题；最终 3D 合成截图中标题、封面、暂停态播放图标一致。过渡中允许保留旧批文字，同时撤掉过期封面，不允许把新标题与旧批封面拼接。

一首曲目的 MediaRemote 英文标题与 AppleScript 中文标题不一致，继续整组 AppleScript 回退并显示占位封面，未通过放宽配对规则取得图片。测试期间 Music 后来处于暂停态，保留该最新状态，没有回写音乐库、喜欢或音量；不把最终暂停截图冒充仍在播放。

**跨屏与 Space**：

- 实际覆盖内置 1352×878 屏与 1920×1080 外接 U2790B。稳定面板分别为 `{{550,88},{300,564}}` 和 `{{2186,-16},{300,564}}`，均在对应 visibleFrame 内；实际查看两屏的完整模型与媒体截图。覆盖了这两个显示器之间的面板迁移，没有验证更多屏幕排列、缩放组合和拔插。
- 用户明确补充授权 CGEvent 仅发送 Control+左／右并恢复原 Space。工具键盘输入曾被 Music 当作切歌；系统级注入未使活动 ID 变化，未记作通过，也未改系统快捷键设置。随后用户手动切换，独立读取确认外接屏 `10 → 5 → 10`、内置屏保持 1；窗口列表随之从当前桌面变为其他桌面，再恢复当前桌面。
- Space 切换样本中曾出现约 1.26 秒的空窗口列表，并伴随媒体兴趣／连接重建。代码中 Space 通知会清空 AX 缓存，而 overlay 上下文使用首个窗口 ID；这是后续需要针对“后台重枚举期间保留经当前 CG／Space 重新确认的候选”做回归的点。本轮没有直接修改缓存失效语义，以免在没有进一步实测时引入关闭窗口残留。
- 外接屏新 Space 上持续显示 3D 的截图未取得。为避免回到聊天立即切回原 Space，额外安装了被动观察器；用户随后选择暂不再切换，已停止观察，不再追加操作。独立人工 Space 探针因等候超过 360 秒且未及时发出 finish 而超时失败，该轮不计通过；最终自动采样另起新进程、显式结束并成功。可确认真实 Space 切换及归属变化，不能声明完整跨 Space 3D 视觉验收完成。

**最终验证与交付**：

- `make build`：`Build complete!`；`make test-unit`：`Executed 843 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`。最终显式真实媒体验收：1 项通过，采集首次、两次重复打开及正式合成截图。9 项跳过仍为 opt-in 验收项，未把跳过当通过。
- `make plugin-preview-build` App／Worker 成功；`Tests/PluginPreview/run-background-input-tests.sh ../switchly-plugins`：22 条 PASS、`SUMMARY background-input passed`；`make plugin-preview-contract-check` 契约哈希、renderer revision、33 个共享核心类型检查通过。
- 已执行 `make run` 启动最终 Debug，核对 PID 81787 及 `DerivedData/Build/Products/Debug/Switchly.app/Contents/MacOS/Switchly`，没有混用 `build/` 或发行副本。
- `./verify.sh`：0 失败、2 警告（未提交修改、超长文件）；`git diff --check` 通过。首次曾误将 build 与 test 并发运行而争用 build.db，随后改为顺序执行；没有将那次构建失败记作通过。CoreSimulator 版本提示仍存在，未阻止最终 macOS 构建／测试。
- Finder 测试窗口经系统菜单移到外接屏后已移回内置屏；未改变 Dock 或系统快捷键设置。Space 恢复到 10 的记录已核对。正式源码、原生测试和记录留库，临时探针、合成帧、日志、采样及被动观察器在记录脱敏结果后清理。保留其他并行任务修改，未提交、推送或发布。

**剩余项**：完整跨 Space 3D 视觉、上述空列表导致的插件重挂载、首次系统初始化尖峰、稳定条件下的长尾分布及 GPU 硬件时间仍待后续验证；本轮不将这些项标记完成。

## D11 — Dock 性能改动提交集成（2026-11-11）

**范围与来源**：按用户“提交并提 PR 合并入主干”的指令，在系统临时目录的隔离 Git worktree 集成 D07–D10 的性能实现、回归与实测记录。原工作区的独立锁文件 schemaVersion 2 迁移、脚本、测试及相关文档保留，不纳入本性能提交；其他窗口截图 PR 不在本次合并范围内。宿主继续沿用主干 schemaVersion 1，显式更新来源和音乐插件三文件摘要，不改变天气与鲸娘制品。

音乐外仓新增可选 `prepare(ctx)` 的 5 个文件已通过 PR [switchly-plugins #3](https://github.com/leungingit/switchly-plugins/pull/3) 合入 `main`；宿主锁定不可变提交 `5665e5871b6767519892c4f2448894e3e6ea62ca`。合并树与已验证的外仓分支逐字节一致；本次不发布、不调整版本或签名配置。

**本次隔离集成复核**：

- 外仓 `npm test`：47 通过、0 失败；`npm run build`：默认与 v2 两条发行线各 3 个插件。
- 宿主 `make update-plugin-lock`、`make verify-plugin-release`、`make bootstrap` 成功；`make build` 输出 `Build complete!`。
- `make test-unit`：`Executed 843 tests, with 9 tests skipped and 0 failures`，`TEST SUCCEEDED`。9 项为条件验收项，未计为通过。
- SDK `npm test --prefix Plugins/sdk`：6 通过、1 跳过（隔离工作树没有 tsc）；CLI `npm test --prefix Plugins/cli`：67 通过、0 失败。
- `make plugin-preview-contract-check`：契约哈希、renderer revision 一致，33 个共享核心类型检查通过；`make mediaremote-adapter-test`：13 项通过。
- `./verify.sh`：0 失败、2 警告（提交前 dirty、超长源文件）；`git diff --check` 通过。CoreSimulator 版本提示未阻止 macOS 构建与测试。

**验收边界**：D07–D10 的已查看原生截图与实测口径继续适用，本次 Git 集成未重新触发播放、切歌或 Space 切换。完整跨 Space 3D 视觉、Space 切换期间短暂空列表／插件重挂载、首次系统初始化尖峰及长尾分布仍未完成；不能因本次提交与合并将其标记解决。依据项目 AGENTS §8 和交付自检清单核对范围、验证、文档与卫生；临时构建、日志和隔离工作树在交付前清理，已有工作区修改保持保留。
