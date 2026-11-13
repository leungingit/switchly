# 活动时间线实施与验证记录（2026-11-12）

> 用户授权：「按计划推进，先验证后完整实现」。覆盖 M0～M3；AI摘要不在本轮。正式合同见 [AT-D08～D14](../plugins/activity-timeline-plan.md)。本记录区分实现、自动化、当前机器系统证据和待验场景，不代表用户最终视觉批准。

## AT-V01 验证先行与范围

先读取分支 `docs/activity-tracking-plan` 的固定提交 `1cb0b7d`、现行隐私/插件合同和源码；原工作树四处修改（AGENTS、CONTRIBUTING、RELEASING、插件外迁台账）保留。前一轮评审文档也保留。

先执行独立原生能力探针，再写模型回归与存储回归后接生产入口；没有为验证开启用户的真实活动记录。探针创建自己的NSPanel，仅打印能力布尔值：

```text
nativePanelCreated=true
finiteIdleSeconds=true
sessionStateAvailable=true
onConsoleSignalAvailable=true
workspaceNotificationCenter=true
lockSignalAvailable=false（未锁屏时该字典字段缺席，不据此宣称锁屏检测失败或通过）
```

单独状态探针使用正式实现同样的NSWorkspace通知中心和分布式锁屏通知，仅记录状态名。用户手动锁屏/解锁后实际收到：

```text
ready:仅观察锁屏/睡眠/会话状态，不记录应用或个人内容
locked
unlocked
```

这证明当前机器锁屏通知可用，不等于正式采集器在真实业务中的整段时长已验收。未主动替用户锁屏、休眠或切换用户。

## AT-V02 实现范围

| 子系统 | 实际落地 |
| --- | --- |
| 采集 | 复用AppActivationTracker通知源，锁外订阅回调；主线程轻量状态机，单调计时、墙钟定位，空闲回退、阻断/恢复、关闭/退出路径；30秒检查点，退出最多等待0.5秒 |
| 存储 | 单一私有JSON，默认400天/100000段/64MiB；按最旧淘汰，包含损坏备份预算；读取拒绝过期，新schema不覆盖，超大文件分配前拒绝；文件身份/mtime/大小验证解码缓存 |
| 写入失败 | 已结束区间保留在有界重放队列，不因一次I/O失败立即丢弃；同一代次按原顺序重放，空闲修剪先于恢复后的新区间 |
| 设置 | 旧设置decodeIfPresent默认关闭；记录/截图分开确认，时长与截图保留、排除、截图允许应用、清除；不读标题、不保存输入内容 |
| 插件面板 | 通用surfaces、panel槽位、菜单入口；app/window为null、presentationID；共享VM可见性租约；动作/render串行pump，有界动作队列、关闭取消和可见期刷新 |
| 查询 | 异步summary/sessions/snapshots，时间桶、半开裁剪、时区/DST、游标绑定查询与revision、条数/字节/并发预算 |
| 授权 | 预装同样确认activity.read/activity.snapshots；JSC最终交付点复核线程安全代次，外层调用结束按callID取消活动任务；清除/撤权后旧引用与排队结果失效 |
| 截图 | 30秒停留、同应用跨session每10分钟最多一张、明确应用允许列表；严格AX聚焦身份，复用CG/SCK有界底层，不读旧缓存；最长边640、单图1MiB、默认7天/总计256MiB；AX严格查询0.5秒消息超时，取消时保留执行所有者至任务返回，避免积压后台查询 |
| 图片展示 | 宿主按插件身份解析短期UUID引用，JS无像素/路径；读取再次校验授权、文件保留期与代次；文件读取桥禁止穿透Activity目录，父目录授权的list/read/stat/递归scan均有回归覆盖 |
| 外仓 | 新增com.switchly.activity-timeline；上午/下午/日/月/年/自定义，分组排行、区间/截图分页、空/无权/失败状态；JS/专属文案/算法测试只在外仓 |
| 工具链 | SDK类型/构造器，CLI/schema/能力清单/契约哈希，Preview/Worker纯activity夹具，后台panel渲染与动作，合成原生验证工具 |

首次真实JSC集成暴露并修复了错误/无权限按钮缺symbol、非法Text style；看图修正了截图过小、中文残留英文、技术结束原因外露。额外修正了多字节长应用名超出条形图标签预算、夹具首个分页cursor为null被拒绝。

## AT-V03 自动化结果

以下命令真实运行；临时脚本、日志、原始截图和临时测试数据放系统临时目录，最终清理，不放入仓库。仓库保留正式测试、合成夹具、源码和本记录。

| 命令/验证 | 结果 |
| --- | --- |
| `make build` | Debug构建通过，包含五个预装插件；主App仍离线构建媒体依赖 |
| `make test-unit` | `Executed 922 tests, with 11 tests skipped and 0 failures`；`TEST SUCCEEDED` |
| 并发与交付边界定向回归 | 5项通过：慢render串行、动作结果优先、stop后丢弃、查询期间换代、结果已返回/尚未交付时换代 |
| 外仓 `npm test` | 61项通过，0失败、0跳过 |
| 外仓 `npm run build` | 默认兼容线4个包，v2线5个包；未修改lines/v1冻结源码 |
| CLI `npm --prefix Plugins/cli test` | 71项通过，0失败、0跳过 |
| SDK（临时TypeScript5.9.3） | 9项通过，0失败、0跳过；包含实际tsc打包类型解析 |
| Worker `Tools/PluginPreview/Worker/Tests/run-tests.sh` | `PluginPreviewWorker tests passed`，包含null首游标与额外私密路径字段拒绝回归 |
| `make plugin-preview-build` | Preview App与Worker构建通过，不引入真实采集器/ActivityStore |
| `make plugin-preview-contract-check` | 七份契约哈希、共享渲染revision、33个核心类型共享源码守卫通过 |
| `./verify.sh` | 0失败、2警告：工作树未提交及长文件提示；未按发布模式执行 |

Xcode输出了本机CoreSimulator组件版本不一致的环境诊断，macOS构建与上述测试仍完成。单测跳过项包括需要显式开启的桌面视觉/媒体/跨Space场景，另有当时锁屏使两项真实窗口动画测试跳过；未把跳过计为通过。已有无关单测编译警告没有借本任务重构。

### 大历史容量探针

独立优化编译（`swiftc -O`）使用10万条、5个合成应用区间，所有文件在系统临时目录，运行后删除。当前arm64/macOS27.2实际输出：

```text
100000段写入毫秒=639.572125
首次读取毫秒=282.713625, 区间数=100000
缓存读取毫秒=25.443625
年范围按月聚合毫秒=75.483959, 桶数=65
```

这不代表Debug渲染耗时、截图能耗、持续运行内存或其他硬件性能。

## AT-V04 渲染与交互证据

- 原生 `SwitchlyActivityProbe` 复用正式Host、Runtime、面板与渲染器，使用内存样例区间/图片。实际查看中文浅色面板，验证排行/会话/双列小图，点击自定义和年范围、日期步进，确认查询状态变化。样例不会启动真实采集。
- 正式后台入口分别运行 `Tools/PluginPreview/Fixtures/Activity/scenario-zh-Hans.json`（600pt、浅色、不透明）与 `scenario-en.json`（390pt、深色、玻璃开、减少动态效果）。两份报告均为status=passed，expectText→自定义action→expectText三步全部通过。
- 两张导出PNG均已实际打开查看：没有文字/日期控件裁切，语言与日期格式跟随场景，窄宽使用同一正式渲染器。纯Worker夹具不提供真实截图，图片展示另由原生合成样例和图片引用回归验证。
- 桌面后续再次锁屏，原生工具无法继续读取窗口。使用自有隐藏NSHostingView补充英文深色不透明面板、中文浅色默认关闭设置、中文深色截图设置；三张PNG均实际查看，无裁切/重叠。全部进程active=false，未激活App、未修改真实设置。输出PNG字节数分别为156195、137509、156577。另完成--system跟随系统主题的原生隐藏截图并实际查看。当时只验证渲染；解锁后的原生点击补证见AT-V06，系统权限交互仍待实机验收。
- 渲染revision：`sha256:0652c0489ef8e304819223295fec1dc7a6af195a08386f0a49e81c8677ca32f3`；契约哈希：`sha256:32d143040808e403db65a0dc35852ea0d9ad78606acb05b27da417fee44acd3f`。旧视觉基线因共享渲染改动失效，未自动接受旧基线。

## AT-V05 状态与剩余边界

| 任务 | 状态 |
| --- | --- |
| AT-T00 / M0 | 已落地合同、隐私、设置与接口同步；推进授权已收到 |
| AT-T01 | 原生基础能力和真实锁屏/解锁通知已验；实际睡眠/唤醒、快速用户切换仍待验 |
| AT-T02～T05 | 已实现，适用自动化与当前原生合成渲染闭环通过；真实用户长时间采集/正式菜单入口体验尚需人工验收 |
| AT-T06 | 完整时间范围与通用控件已实现，时区/DST/长历史/后台动作已验 |
| AT-T07 / M3 | 截图采样、权限、独立存储及图片引用已实现；合成图缩放/清除/授权隔离回归通过；真实跨应用采样、录屏权限撤销、Dock同时捕获预算与能耗待验 |
| AT-T08 / M4 | 未实现，不在本轮 |

macOS12、Intel、多屏/跨Space、快速用户切换与长时间能耗不以当前机器证据代替。原生设置页及深色不透明样例已完成隐藏原生渲染核验；另已用--system原生隐藏渲染实际查看跟随系统主题；原生合成设置点击已由AT-V06补齐；正式偏好设置持久化、系统授权及真实采样仍待验收。

预装锁新增活动插件，原四个插件摘要保持原值；外仓存在未提交的新源码，sourceRevision为null，只用于本地开发。未提交、推送、合并、发行签名验收、打标签或发布；发行前需要外仓先提交，再重新锁定不可变revision并通过发行校验。

## 交付自检

按项目AGENTS第8节及通用delivery-checklist逐项核对：范围/分层/设置兼容/本地隐私/双语/构建与测试/实际看图已覆盖适用部分，未覆盖的平台与真实采样场景如上明确保留。原有用户修改保留；最终链接、差异与工作区卫生检查以交付答复及本记录后续补记为准。


最终自检补记：

- SDK实际含TypeScript的9项测试通过；CLI71项、外仓61项通过。
- `plutil -lint` 两份Localizable.strings均为OK；正式合同、验证记录及工具说明的本地链接有效。
- `git diff --check` 无输出；新增32份未跟踪文本文件无尾随空白；锁文件原四个插件条目逐项与HEAD一致。
- 本轮只保留正式源码、测试、合成夹具、生成工程与文档；原始PNG/日志/探针二进制随任务临时目录清理，不保留失效路径引用。


## AT-V06 用户解锁后的原生交互补证

用户回复「我已解锁，可以继续界面核验」后，启动已构建的SwitchlyActivityProbe，继续使用内存合成数据；未启动真实ActivityTrackingService，设置页tracking依赖为nil，不写正式偏好。

| 场景 | 实际观察 |
| --- | --- |
| 英文深色、不透明面板 | 实际查看可见窗口截图：排行、会话、双列样例图片完整；时长显示1h 30m/30m，未见裁切或重叠 |
| 自定义日期 | 点击Custom后显示Start date与End date (exclusive)，AX标识分别为timeline-range.from/to |
| 原生日期步进与键盘 | 对结束日期执行Increment，11/13/26变为12/13/26；聚焦该日期并按Down，回到11/13/26，控件仍持有焦点 |
| 小时分组 | 点击By hour，选中值变为1，条目显示09:00与10:00时间桶及对应应用，不混为同名应用单条 |
| 取消开启记录 | 点击记录开关出现独立确认，按Escape取消后Value仍为0，截图开关保持禁用且为0 |
| 允许记录 | 在合成状态中点击允许后，记录Value为1；截图开关可操作但仍为0，未连带开启 |
| 截图独立确认 | 点击截图开关显示单独确认及7天/256MiB说明；允许后Value为1，展开保留期、允许应用及权限不足提示 |
| 截图保留期 | 通过原生菜单将7天改为30天，收起菜单后回显30天；只修改合成State |
| 关闭流程 | 关闭截图后对应设置收起；再关闭记录后，两项Value均为0，截图重新禁用 |

设置页默认关闭状态及展开状态的可见原生截图均实际查看，无布局裁切或重叠。确认sheet的文字、按钮与取消/允许行为通过AX及返回页面状态确认；工具两次捕获该系统sheet均返回白图，因此**没有判定弹窗外观通过**，仍需有效截图补证。未因截图失败降低视觉门槛或修改系统授权。

本轮仅补充验证记录，未修改运行代码、双语资源或制品锁，不重复运行此前已通过且未变化的构建/单测；不将合成设置点击等同于正式设置持久化、真实采样、权限撤销或用户最终视觉批准。

## AT-V07 正式应用实机验收阶段记录（最终结果见 AT-V09）

本轮由用户明确授权验证正式应用的设置持久化、真实记录、截图采样和权限撤销。固定应用路径为工作区 `DerivedData/Build/Products/Debug/Switchly.app`，不混用下载目录或全局 DerivedData 的副本。开始时活动库为 0 段、无截图；只保存活动设置及本插件授权的测试前状态，不导出其他设置、密钥或个人内容。

- 正式偏好设置确认记录与截图分开开启；截图保留期从 7 天改为 30 天。重启后 UI 和持久化 JSON 均保留 `enabled=true`、`screenshotsEnabled=true`、`screenshotRetentionDays=30`，允许截图列表初始仍为空。
- 已真实查看并保留[记录确认弹窗](activity-timeline-assets/recording-confirmation.png)和[截图确认弹窗](activity-timeline-assets/screenshots-confirmation.png)。系统 `screencapture -R` 抓取设置窗口所在屏幕区域能包含确认层；单独抓取父窗口不含弹窗，界面工具单独抓取 sheet 返回白图。两张有效图中文字、按钮及取消焦点完整，补齐 AT-V06 对这两个弹窗的缺失证据。
- 应用选择器调试期间定位到系统 `OpenSavePanels` 的 `NSXPCSharedListenerErrorDomain Code=2`，其前置日志为 `SecCodeCopyGuestWithAttributes ... -67049`。验收进程运行期间构建／测试重签同路径副本会干扰系统代码身份校验；已退出进程，完成构建、测试及 `codesign --verify --deep --strict` 后重新启动固定副本。临时模态改法未解决问题，已还原，保留选择器请求／返回码日志和区分两个应用列表的无障碍标签。固定副本已能通过原生选择器选择本次创建的 A 应用，并将其写入唯一允许截图列表。
- 最新 `make build` 通过；`make test-unit` 实际输出 `Executed 922 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`；完整签名校验退出码 0。后续实机验收期间不再构建／重签此副本。其 `Switchly.debug.dylib` SHA-256 为 `e0dcdcf664a0f6c6a535eadea0523ef7e5a7d6645e24474e726c68c17325f7e4`。
- 正式采集器已将本次 A 应用的两次真实前台停留写入活动库，分别约 0.247 秒和 6.064 秒，均因切换结束。记录字段仅为 `appName/bundleID/start/end/seconds/endReason/id`，没有标题或输入字段；活动目录 `0700`，活动文件 `0600`。
- A 尚未连续前台停留 30 秒：实际前台被其他桌面操作切到 ego lite／Tern。两次观察截图数均为 0，不能将其写成截图采样通过。已请求用户暂停其他桌面自动化并保持 A 前台至少 40 秒；截图采样、未允许应用拒绝、冷却、权限撤销与恢复、测试后开关恢复仍需后续结果更新。

本节是进行中的实测记录，不替代 AT-V05 中仍未完成的验收项。

## AT-V08 真实采样发现的进程身份缺陷

用户保持 A 前台后，正式采集器记录到 65.370 秒检查点，随后同段增长至约 177.782 秒，但截图仍为 0，排除“停留不足”作为该次失败的解释。正式权限页刷新确认辅助功能与屏幕录制均启用。

定位发现活动采样构造 `WindowCaptureTarget` 使用 `NSRunningApplication.launchDate`，而 `RawWindowCaptureService` 校验使用现有的 `WindowCaptureProcessIdentity.startedAt(pid:)`。对本次 A 进程分别读取两种身份，实际输出：

```text
kernelStartAvailable=true appKitStartAvailable=true
identityEqual=false
startDifferenceSeconds=-0.010618925094604492
```

这会触发 Raw 捕获器的启动时间不相等检查，令有效窗口被当作进程已更换。已修正活动采样入口，复用与 Dock 截图相同的内核身份工具；未放宽严格相等、PID／窗口归属、捕获前后、取消或授权门禁。另增加限于既有采样尝试频率的状态日志，只记录 `focusedWindowUnavailable`、`WindowCaptureFailure` 原因码、`cancelled`、`storageFailed` 或成功，不含应用、标题、路径或屏幕内容。

修正后 `make build` 通过，`make test-unit` 再次输出 `Executed 922 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`，完整签名校验退出码 0。随后启动固定正式副本，开始重跑同一真实窗口；第一次重跑 A 在 11.390 秒失去前台，未到采样门槛，不能作为修复后的采样成功或失败证据。已请求再次保持 A 前台 40 秒，最终采样、撤权与恢复仍等待后续补记。AT-V07 的固定二进制哈希是本修正前的阶段记录，不代表当前修正后的二进制。

## AT-V09 正式实机验收结果与还原

本节接续并更新 AT-V07～V08 的阶段状态。验收对象为工作区正式 App，不是 ActivityProbe 或 Preview；截图来源是宿主之外的独立原生 A 测试进程，内容只包含本次编写的样例文字。

| 验收项 | 实测结果与证据 |
| --- | --- |
| 设置持久化 | 正式 UI 开启记录、单独开启截图，将截图保留期改为 30 天；退出、重启后 UI 与 JSON 保持一致。通过原生应用选择器添加 A，实际持久化为唯一截图允许项 |
| 真实活动记录 | A、B 的前台切换进入正式活动库；A 包含 38.019 秒的修正后真实区间，修正前还有 177.782 秒区间。没有保存窗口标题或输入内容；目录／文件分别为 0700／0600 |
| 真实截图采样 | 进程身份修正后，正式日志于 14:36:54 输出 `Activity screenshot saved`；[真实 A 小图](activity-timeline-assets/real-sample-A.jpg)已实际查看，640×408、20286 字节、0600。正式插件面板获批后能展示该图片，JS 仍只持有不透明引用 |
| 确认弹窗 | [记录确认](activity-timeline-assets/recording-confirmation.png)、[截图确认](activity-timeline-assets/screenshots-confirmation.png)、[插件授权确认](activity-timeline-assets/plugin-confirmation.png)均取得有效图片并实际查看；文案及按钮完整。前两项补齐 AT-V06 的白图缺口 |
| 系统录屏撤销 | 系统设置将 Switchly 开关从 on 改为 off，用户自行完成 Touch ID。macOS 明确提示旧进程可继续录屏至退出；退出并按完整路径重新启动正式副本后，[权限页识别缺少录屏](activity-timeline-assets/screen-permission-revoked.png)，辅助功能仍启用。观察期图片数保持 1；不把系统要求退出前的旧授权期算作撤权生效 |
| 插件访问撤销 | 已实际授权读取活动／展示截图并看到正式面板数据；随后禁用插件，重新打开同一入口，仅显示[启用提示](activity-timeline-assets/plugin-revoked.png)，没有历史排行或图片。该实测覆盖整体禁用后的访问拒绝；两项权限分别撤销及在途旧引用由现有自动化覆盖 |
| 正式中文显示 | 发现并修复 Host 未传应用语言、Runtime 缓存未考虑语言的问题；面板列表与窗口初始名称也显式使用应用语言。最终正式窗口实际显示中文分段、分页、会话、记录暂停与截图关闭状态；[中文空范围截图](activity-timeline-assets/panel-zh-restored.png)选择上午以避免将本次其他真实应用使用记录写入审阅资产 |

### 最终代码及自动化

- `ActivityTrackingService` 复用 `WindowCaptureProcessIdentity`，保留 PID／启动时间／窗口归属、前后聚焦、取消与授权复核；只新增有界采样尝试中的无内容原因码日志。
- `PluginHost` 注入应用语言并将语言纳入 Panel／Dock 共用 Runtime 缓存身份。设置读取依赖可注入，新增 `testHostLanguageChangeRebuildsPanelRuntimeAndLocalizesJSCContent`，通过真实 JSC 验证中文输出、切换英文、替换旧 Runtime 及英文输出。
- 最终 `make build` 通过；`make test-unit` 输出 `Executed 923 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`，新增语言回归通过。跳过项未计为通过。
- `codesign --verify --deep --strict DerivedData/Build/Products/Debug/Switchly.app` 退出码 0；最终 `Switchly.debug.dylib` SHA-256 为 `e81fa46980db25a204384890e7a4968891680681e0e2051c13552c8cc274b500`。验收使用该固定副本后不再重签。
- `./verify.sh` 为 `PASS — 0 check(s) failed, 2 warning(s)`，警告为未提交工作树与既有长文件提示；`git diff --check` 无输出。

### 限制与恢复

多屏共用同一个会话前台应用。将 A 移到另一屏不能让用户操作其他应用时继续满足“连续前台至少 30 秒”；本轮多次操作被其他桌面／浏览器任务切走，未通过放宽采样条件取得结果。用户要求后，不再重复请求人工保持前台。系统录屏撤销后的数据库未形成可确认满足 30 秒门槛的 A 新区间，因此本轮只确认真实撤权状态、重启后的权限降级及未新增图片，**不宣称已完成同等连续停留条件的采样阻断对照**。B 仅记录到约 21.760 秒停留，未计为满足门槛的白名单拒绝实测；同应用 10 分钟冷却、恢复录屏后的再次采样、持续能耗、睡眠／快速用户切换、macOS 12／Intel／多屏跨 Space 仍保留独立验收边界。未实际补证已显示面板在禁用瞬间的图片消失延迟。

验收后已退出自建 A／B 工具及本次打开的系统设置；活动设置恢复为记录关闭、截图关闭、截图允许列表为空、截图保留 7 天、活动保留 400 天及原排除列表。临时活动插件授权键已移除，恢复为尚待用户批准的原状态；没有改动其他插件授权。系统录屏开关恢复 on，按完整路径重启后正式日志确认 `Required permissions are already granted`，只运行工作区副本。

开始时活动库为 0 段；本次实际产生的 103 段活动与 1 张 A 小图仍保存在 App 私有活动库，未擅自执行“清除活动记录”。它们受恢复后的原保留期约束，记录及采样已停止。审阅目录只保留上表明确引用的最终证据，临时探针、脚本、调试日志与中间白图在系统临时任务目录清理；不提交、推送或发布。

按项目 AGENTS 第 8 节及通用 delivery-checklist 逐项核对范围、分层、并发／生命周期、隐私、双语、构建测试、实际看图与工作区卫生。原工作树修改及其他会话新增文件保留；未覆盖的真实条件按本节列明，不作全平台完成声明。

## AT-V10 撤权阻断、恢复采样与真实 600 秒冷却

本节更新 AT-V09 中这三项尚未完成的实机状态。用户要求尽量自行自动化、不再反复人工保持前台；本轮窗口前台请求、等待及证据读取均自动执行，仅在已有软件更新密码弹窗和 macOS 隐私设置 Touch ID 处交由用户处理。没有读取密码、改 TCC 数据库、修改时钟、注入虚拟时间或缩短生产采样常量。

新增独立的[连续实机验收窗口](../../Tools/ActivityTrackingAcceptance/README.md)，只操作自身 A／B 窗口并在临时目录记录实际前台布尔值、连续时间和空闲秒数；有停止按钮、20 次请求／150 秒阶段上限。工具自身不采集、不截图、不改设置或系统权限。所有图片和活动区间由工作区正式 App 产生。临时活动设置只允许这两个测试应用截图，并额外排除当时其他运行应用，结束后完整恢复原活动设置；既有历史未清除。

### 可审计结果

具体时间、独立前台观测、正式区间、截图引用及二进制摘要保存在[实机证据 JSON](activity-timeline-assets/live-cycle-evidence.json)。以下时间均为 Asia/Singapore（UTC+08:00）。

| 场景 | 判定依据 | 结果 |
| --- | --- | --- |
| 系统撤权后阻断 | 系统设置录屏 off，正式进程 PID 70146 重启后识别权限缺失；B 独立前台观测达 98.001 秒，正式库在观测时同段达 96.990 秒，退出冲刷后该段共 112.593 秒；均超过 30 秒门槛，空闲小于 300 秒；B 没有新截图 | 通过，补齐上一轮仅有权限状态、没有有效停留对照的缺口 |
| 恢复后新采样 | 系统设置恢复 on 后启动固定正式副本 PID 94953；B 正式区间达 64.862 秒，独立观测达 64.501 秒；15:42:31.585956 保存[恢复后 B 图](activity-timeline-assets/cycle-restored-B.jpg)，实际查看为本次样例窗口，640×424 | 通过 |
| 跨活动会话冷却 | 成功采样后切到 A，再返回 B；新 B `sessionID` 与首张图片所属区间不同，正式区间达 58.347 秒，独立观测达 58.001 秒，但 B 仍只有首张图 | 通过：新活动会话没有绕过冷却 |
| 真实 10 分钟间隔 | 正式 App 始终为 PID 94953；598.769 秒时索引仍只有首张 B 图，监视期间 600 秒前所有记录均为 1；15:52:36.595527 保存[冷却后 B 图](activity-timeline-assets/cycle-cooldown-B.jpg)，与首张实际 `capturedAt` 相隔 **605.009571 秒**，属于另一活动区间 | 通过：本次实测同应用跨区间的最小图片间隔不少于 600 秒，且到期后恢复采样 |

接近边界的窗口区间发生过短暂前台打断；紧邻 600 秒前的辅助连续计数未达到 30 秒，因此不宣称取得“599 秒时已连续前台 30 秒”的精确负对照。冷却阻断的合格停留依据是较早的新 B 会话 58 秒；索引保留与第二张图片的实际间隔另作独立证据。未将辅助窗口计数、正式区间时长或恢复采样的不同观测混为同一个计时源。

### 发现并修复的冷却起点问题

`lastCapture` 原先写入触发采样 tick 的 `mono`，AX 查找、抓取、压缩及存储耗时会被抵扣。已改为成功 `save` 返回后读取注入的 `uptime()`，从成功落盘完成起计算冷却，保留现有 600 秒常量、同应用跨区间预算、全局 30 秒尝试节流及所有身份／权限复核。本轮完整实时间隔验收作为该修改的集成回归，不添加仅复述赋值实现的单测。

- `make build`：通过。
- `make test-unit`：`Executed 923 tests, with 9 tests skipped and 0 failures`、`TEST SUCCEEDED`；跳过项未计为通过。
- 正式固定副本完整签名校验通过；恢复及整个冷却期间不构建、不重签、不重启它。
- 验收窗口源文件与实际测试的源文件逐字节相同，已独立 `swiftc -O` 编译；所有生成的 App 与轨迹均在系统临时目录。
- `./verify.sh`：0 失败、2 警告，仍为未提交工作树与既有长文件提示。

本轮验证的是同一正式服务生命周期内跨活动区间的冷却；没有把宿主重启前后的记录拼为该证明。睡眠／快速用户切换、macOS 12／Intel、持续能耗以及已显示图片撤权瞬间的消失延迟仍不在本次完成声明内。

### 收尾状态

已正常退出 A／B 验收应用，恢复活动设置为记录关闭、截图关闭、截图允许列表为空、截图保留 7 天、活动保留 400 天及原排除列表；系统录屏授权恢复 on，其他插件授权未改动。正式 App 已按完整路径重新启动。独立核对持久化文件及 Foundation 设置读取，均与本轮开始前活动设置一致。

既有数据未清除：当前活动库共 121 段、4 张图，其中本轮测试应用为 14 段，新增 A 一张、B 两张小图。临时文件清理后只保留正式验收工具源码／说明及经检查的审阅证据；没有提交、推送或发布。


## AT-V11 面板材质、设置归属与菜单栏直达（2026-11-12）

用户实机指出插件选择器和活动面板过度透明，并要求将活动设置放入插件设置、从菜单栏直接打开活动面板。新增合同 AT-D15，覆盖原先仅从通用选择器打开的交互安排。

问题与修改：

- 插件选择器原先没有内容背景；独立面板在透明 NSPanel 上只画低透明度底色及控件级 `liquidGlass`，未拥有偏好设置的完整背景。两者现统一复用 `WindowCrystalModifier(style: .preferences)`，使用相同的 `windowGlassDensity`、`crystalMaterial` 和主题；AppKit 配套使用透明标题栏、完整内容背景和全尺寸内容窗口，保留屏幕边界约束。
- 「记录应用活动」、截图采样、保留期、应用名单和清除操作整体从「通用」移到「插件」，复用原设置 Binding 和 `SettingsService`，不迁移或重置持久化数据。
- 状态菜单异步发现声明 `panel` 的插件，按 manifest 本地化名称直接列出入口，活动时间线不再需要先经过选择器。保留通用选择器；菜单发现不启动 Runtime 或读取活动。打开仍走正式 `PluginPanelModel` 和既有权限检查，没有按活动插件 ID 添加宿主业务分支。
- 合成探针的 `--opaque` 同步设置 `glassStyle = .opaque`，与普通窗口共享材质的关闭语义一致。

已执行验证：

| 验证 | 实际结果 |
| --- | --- |
| `make build` | 首次发现新增闭包中的 Swift 6 显式 self 警告，已改为类型限定 selector；随后构建通过 |
| `make test-unit` | `Executed 923 tests, with 9 tests skipped and 0 failures`，`TEST SUCCEEDED` |
| `SwitchlyActivityProbe` 构建 | 通过；复用正式 coordinator、ViewModel、插件脚本与原生材质，只使用合成数据 |
| 浅色、深色、跟随系统且关闭玻璃 | 三种原生窗口截图均已实际查看；完整窗口背景、标题、筛选器、时长条和图片内容可见，未见布局遮挡；单窗口截图不证明桌面合成透射，因此不据此宣称真实背后应用干扰已验。这是合成内容观察，不代表正式数据采样或用户最终视觉批准 |
| `./verify.sh` | `PASS 0 check(s) failed, 2 warning(s)`，仍为既有脏工作树及长文件提示 |
| `git diff --check` | 通过 |

正式截图：[浅色合成面板](activity-timeline-assets/panel-style-light-fixture.png)、[深色合成面板](activity-timeline-assets/panel-style-dark-fixture.png)、[跟随系统／关闭玻璃](activity-timeline-assets/panel-style-system-opaque-fixture.png)。截图仅包含自有样例内容，未保存用户附图或桌面中的其他工作内容。

原生自动化入口限制：没有可见窗口时，`cua.getApp`／菜单操作持续返回 `timeoutReached`，Finder 操作正常。临时 XCUITest 从应用菜单打开设置时，系统返回 `MenuBarItem {{0.0, 29.0}, {0.0, 0.0}} ... is not hittable`；标准设置快捷键亦未打开窗口。这些尝试失败，不计为通过。它们未触达设置页或改变设置，未将不成立的入口假设作为仓库回归测试保留。已请求用户仅打开一次正式窗口，之后由 Agent 接手，不请求人工保持前台。

Xcode UI 测试还改写了包内 `Resources/MediaRemoteAdapter` 的二进制，完整签名校验指出该资源被修改；因此停止正式副本后重新构建，完整校验后才继续固定副本的验收，不在运行中构建或重签。

正式选择器、菜单直达与设置位置的实机核验仍待补证；不能将上方合成截图当作这些路径已经通过。


## AT-V12 插件授权引导、活动趋势与正式面板核验（2026-11-12）

本节接续 AT-V11。用户已按上一轮菜单栏操作请求打开活动面板并提供附图，随后要求修复“记录／截图和插件均已开启却仍提示无权限”，并增加曲线等活动图表。本轮没有使用 Skills，没有提交、推送或发布。

### 问题、实现与证据

1. **授权引导误导**：正式设置页同时显示插件启用和“尚未允许”，持久化中没有活动插件 grant。原清单 `defaultEnabled: true` 使新插件看似已启用；采集开关也不能代表已授予 `activity.read`／`activity.snapshots`。现将活动插件默认关闭，首次启用走既有明确确认；已有用户授权继续沿用。通用设置卡片增加「检查权限…」，宿主独立面板明确列出待确认权限并定位对应插件设置。待确认读取权限时不加载活动 Runtime；仅缺截图权限仍可展示已获授权的时长。没有自动放行权限或修改系统 TCC。
2. **设置归属**：采集、截图、保留期、应用名单和清除入口归入声明 `activity.read` 的插件展开卡片，复用原 `SettingsService` Binding。正式「通用」页不含这些选项。实际看过[授权后的插件卡片](activity-timeline-assets/plugin-settings-authorized.png)；未见重复顶层活动设置或控件遮挡。
3. **图表**：新增时长／应用数概览、按范围选择小时／日／月桶的折线与面积图，保留应用条形图、分页会话和截图。通用 `lineChart` 复用 label／非负有限秒值，最多 64 点；协商复用 `ctx.uiFeatures.lineChart`。Dock 和 scene3d 纹理拒绝它，panel 的普通 2D fallback 继续遵循既有规则。最坏树仍最多 64 节点，会话每页 6 条。趋势失败单独降级，不阻断排行和会话。
4. **时间边界**：同桶跨应用求和并按时间排序；只在保留范围与已发生的查询区间补零。`availableFrom: null` 不补零；保留边界位于 14:03 时仍保留相交的小时／日／月桶。小时推进使用 epoch，夏令时回拨的两个 01:00 分开保留，并通过 UTC offset 区分标签。没有伪造未来或已过期时段。图表时长提示保留秒数，避免两单位格式器把 2 小时 4 分 50 秒舍入成 2 小时 5 分造成概览观感不一致。
5. **正式授权已生效**：原生界面展示确认的两项权限；用户回复“允许这两项授权”后，当前 grant 为 `isEnabled: true`、`activity.read` 和 `activity.snapshots`。正式面板已显示真实时长、会话与已有 A／B 样例截图，原无权限提示消失；日／月切换及新增趋势也已实机看图。本机私有图证 `activity-chart-live-light.png`（含真实应用使用历史，未随公开仓库上传）在最终秒精度调整前完成，不冒充最终主题和图表版本全部验收。
6. **原生再次打开**：增加标准 `applicationShouldHandleReopen`：已有进程无可见窗口时显示偏好设置。按完整路径启动后再次 `open`，已多次自行取得正式设置窗口，无需用户代开。菜单索引失效时重新绑定完整路径，也已成功导航 `Settings…`。操作规则见 [AUTO-D02～D03](../engineering/native-ui-automation.md)。
7. **正式选择器**：已实际查看[正式浅色插件选择器](activity-timeline-assets/plugin-launcher-live-light.png)，背景与偏好设置复用相同普通窗口材质；点击其活动入口可打开正式数据面板。菜单栏直达的用户辅助证据来自本轮用户按前次请求打开面板的附图；Agent 尝试的状态栏自动定位在本机 XCUITest 的应用／SystemUIServer／ControlCenter 层级均未找到目标，诊断尝试失败，不计为自动点击通过，也不保留不成立的测试入口假设。

### 一并定位并修复的快速显隐问题

全套测试多次出现 `WindowPluginCardLifecycleTests.testThreeMountedCardsStopAndResumeWithFreshPresentationContexts` 的第二次挂起超时，日志伴随 `onChange(of: Presentation) action tried to update multiple times per frame`。单独重跑偶尔通过，不能据此忽略。`task(id:)` 仍触发同样保护；最终将展示输入通过 SwiftUI 持有的单次订阅调度到主队列下一轮处理，离屏标记阻止迟到更新，`onDisappear` 立即停止。没有加长超时、减少断言或关闭测试。原测试连续 10 次通过，随后全套也通过。该改动只涉及插件卡片的展示输入调度，保留既有 ViewModel 代次和可见性租约。

### 已执行门禁

| 命令／检查 | 实际结果 |
| --- | --- |
| 外仓 `npm test`／`npm run build` | 66 项通过，0 跳过；两条离线发行线生成成功 |
| SDK `npm test` | 11 项通过，0 跳过；使用本机已有的 TypeScript 6.0.3 缓存完成打包后类型解析，没有新增依赖或联网安装 |
| CLI `npm test` | 72 项通过，0 跳过 |
| `make update-plugin-lock` | 仅活动插件 `contentHash` 改变；仍为本地未提交制品，不宣称发行锁定 |
| `make build` | 最终通过，无新增源码警告 |
| `make test-unit` | 最终 `Executed 927 tests, with 11 tests skipped and 0 failures`，`TEST SUCCEEDED` |
| 生命周期原测试 `-test-iterations 10` | 10 次通过，保留原断言与超时 |
| `Tools/PluginPreview/Worker/Tests/run-tests.sh` | `PluginPreviewWorker tests passed` |
| `make plugin-preview-contract-check` | 契约哈希、渲染器 revision 和共享源码守卫通过；新图表源码计入 renderer revision |
| `SwitchlyActivityProbe` 构建 | 通过；支持未授权合成元数据检查，不改变真实 grant |
| `codesign --verify --deep --strict` | 最后一次构建后通过；未在固定副本运行期间构建或重签 |

11 项跳过中，9 项是既有显式选择的渲染／跨 Space／媒体等实机场景，另 2 项 Dock 动画测试明确因锁屏跳过；没有为本轮添加跳过条件。最终实际值及二进制摘要见[证据 JSON](activity-timeline-assets/panel-permission-chart-evidence.json)。

### 当前收尾与待补项目

- 活动设置、截图允许列表、保留期、外观及其他插件 grant 与本轮开始前逐字段一致；仅保留用户本轮明确确认的两项活动插件授权。既有活动与图片未清除。
- UI 自动化明确报告 Mac 已锁屏，已请求最小必要的手动解锁。最终秒精度版本的正式深色／跟随系统／关闭玻璃图表与待授权提示截图仍待解锁补证；不能把之前看过的浅色图表、单窗口捕获或合成截图当作这些状态已经通过。
- macOS 12、Intel、跨 Space 多屏、长期能耗和其他 AT-V10 保留的平台边界没有扩大完成声明。用户最终视觉批准仍由用户决定。


## AT-V13 会话与截图改为纵向时间线（2026-11-12）

按用户最新要求和 AT-D17，替换原先分离的会话文字块与截图网格，概览、趋势和应用排行继续保留。没有新增权限、采集或存储类别。

### 展示与关联

- 时间线按条目时间由早到晚排列；左侧本地日期与 `HH:mm:ss` 时间，中间连续轴线／节点，右侧会话内容。截图以当前已载入会话的明确 `sessionID` 归入该会话，显示拍摄时间；旧响应缺少关联或所属会话不在本页时，按 `capturedAt` 独立排列，不按同应用或相近时间猜测归属。
- 新通用节点 `timeline` 复用现有内容节点，最多 12 个 `{timestamp,content}`，子树继续计入 64 节点／深度 8。`ctx.uiFeatures.timeline` 协商，旧宿主回退为相同顺序、保留时间的纵向列表。Dock 和 scene3d 纹理拒绝此节点，panel 的普通 2D fallback 保持既有规则。
- 两个分页仍独立，上一页／下一页的可访问名称包含“会话”或“截图”；页面说明明确时间线仅含当前已载入的页。未取得截图权限时只显示可读会话与权限提示，不把未读取的截图误报为不存在。截图引用不重复输出。
- 会话区间与拍摄时间精确到秒，跨午夜显式显示终点日期。窄版实际看图发现默认单行会省略长名称，已让时间线标题最多显示三行、时间说明最多两行；没有改变其他插件文字的默认行数。

### 看图证据与边界

本轮使用真实外仓插件脚本、正式宿主解码器和正式 `PluginTimelineView`，注入纯合成会话与图片。已实际查看：

| 状态 | 原生合成布局 | 核验结果 |
| --- | --- | --- |
| 浅色、760pt | [浅色时间线](activity-timeline-assets/vertical-timeline-light.png) | 时间、日期、区间、两张图片归位，轴线连接各会话，未见遮挡 |
| 深色、760pt | [深色时间线](activity-timeline-assets/vertical-timeline-dark.png) | 文字、时间轴与截图内容可辨识 |
| 英文、400pt | [窄版长名称](activity-timeline-assets/vertical-timeline-compact-en.png) | 长应用名实际换行、图片随可用宽度缩小，未见裁切或横向越界 |

以上均使用 `--render-timeline --opaque` 隐藏原生渲染，进程输出 `active=false`，不排序桌面窗口、不操作全局键鼠、不读取个人活动。两张合成图片分别绑定准确的编辑器会话，并按所选范围过滤。导出背景已填满固定画布，语言环境与正式面板一致；只保留最后实际看过的版本。它们是组件布局／配色证据，不替代真实桌面玻璃、多屏、交互或个人数据展示验收。

### 真实门禁

- `make build` 与最终完整签名校验通过。
- 最终 `make test-unit`：`Executed 929 tests, with 11 tests skipped and 0 failures`、`TEST SUCCEEDED`；其中 2 项因锁屏跳过，9 项为原有可选实机场景，没有增加跳过条件。
- 新增时间戳／条目预算、子树遍历、重复动作 ID、Dock／纹理隔离回归；已有截图集成测试确认公开 `sessionID` 对应真实保存的会话 UUID。
- 外仓 `npm test`：71 项通过，0 跳过；覆盖关联／独立截图、旧响应、旧宿主回退、跨午夜、无截图权限、分页隔离及最坏 64 节点预算；`npm run build` 通过。
- SDK 13 项、CLI 73 项通过，均 0 跳过；既有 TypeScript 缓存完成打包类型解析，未安装新依赖。
- Worker 回归通过；契约哈希、renderer revision、35 个共享类型及工程引用守卫通过。新模型／视图由宿主与预览共享，未复制渲染实现。
- 显式更新锁文件后，只有活动插件制品发生变化；仍为本地未提交制品，未作为发行锁定。`git diff --check` 两仓通过。

实际画布尺寸、二进制摘要与检查摘要见[纵向时间线证据](activity-timeline-assets/vertical-timeline-evidence.json)。最终布局图作为正式审阅资产保存；已在核对正式资产、测试输出和设置未变后，清理本轮纵向时间线与上一轮图表核验所建的两个系统临时目录。

### 运行状态与后续

新版正式 App 已完成构建／签名，最终构建后按固定完整路径重新启动；再次连接原生界面仍明确返回 Mac 已锁屏。此前已经批准的两个活动权限继续保留，活动／截图配置和保留期未改，没有清除历史。解除锁屏后继续补齐正式面板的真实会话／截图关联、深色／跟随系统／玻璃状态及菜单入口证据；本轮不将这些仍受阻的实机项目报告为通过。

按项目第 8 节和通用交付自检清单核对：范围、分层、设置／权限边界、构建测试、合成看图、文档及卫生已核对，真实桌面阶段保留上述未验项。没有提交、推送或发布。

## AT-V14 正式纵向面板核验、AT-INC01 与恢复（2026-11-13）

本轮在解锁后核对固定副本，取得正式浅色、深色、跟随系统、关闭玻璃的会话／截图画面；按实际控件自动翻至第 10 页和第 19 页，截图按明确会话 ID 归位。图表、日期和秒级时长可见。发现并修复过期游标进入持续失败页、时长省略非零秒，以及独立面板未进入系统窗口菜单、滚动穿过标题栏的问题；合同分别见 AT-D18／D19。标准窗口最终框架约束包含原生标题栏。

实机画面（均为事故前的真实数据，未冒充安全修正后的正式弹窗验收）：

- [深色关闭玻璃](activity-timeline-assets/live-history-dark-opaque-2026-11-13.png)、[深色磨砂](activity-timeline-assets/live-history-dark-frosted-2026-11-13.png)。
- [浅色关闭玻璃](activity-timeline-assets/live-history-light-opaque-2026-11-13.png)、[浅色磨砂](activity-timeline-assets/live-history-light-frosted-2026-11-13.png)、[跟随系统](activity-timeline-assets/live-history-system-2026-11-13.png)。
- [正式选择器](activity-timeline-assets/live-launcher-2026-11-13.png)。

**本轮正式验收未通过**：在确认弹窗截图为空白时仍继续操作，发生误清除。完整经过、恢复校验与剩余损失见 [AT-INC01](activity-tracking-incident-2026-11-13.md)。331 条原始区间以事故前 SHA-256 完全匹配重建，并保留 8 条事故后记录；339 条与 3 张原始 JPEG 已写回。第 4 张原始 JPEG 未找回；原截图索引重建为 3 条，不称全部恢复。

按 AT-D20 将确认改为单一状态、每次独立呈现标识与意图校验；清除需准确输入 `CLEAR`，取消清空输入，无默认清除回车动作。新增 6 项状态回归。对正式历史停止清除交互，确认视图仅做隔离夹具渲染；已实际查看中文浅色清除、英文深色记录、中文深色截图内容，空确认词时清除禁用，无文字／控件裁切。这些组件图不替代正式弹窗点击证据。

最终门禁：`make build`、`make test-unit`、Probe 构建和完整签名通过；单测 `Executed 937 tests, with 11 tests skipped and 0 failures`、`TEST SUCCEEDED`。11 项为 9 个既有可选场景和 2 个锁屏窗口动画场景，没有新增跳过条件。外仓 76 项、SDK 13 项、CLI 73 项及 Worker 回归通过；契约／渲染 revision／共享源码守卫通过。最终清单与运行摘要见[恢复证据](activity-timeline-assets/incident-recovery-evidence-2026-11-13.json)。

修正后的正式副本已后台启动，启动后原始 331 条逐字段仍一致，截图数为 3；外观、采集设置、允许列表、保留期和两项插件授权与本轮开始一致。正式菜单栏状态项的 Agent 直接点击及正式确认弹窗有效截图仍未补齐，不把窗口菜单选择或组件图计为这两项成功。

交付自检：已核对项目第 8 节和通用交付清单。范围／契约、双语文案、状态标识与取消、构建测试、合成看图、两仓差异检查已执行；未通过项为本轮正式实机验收、缺失原图及原始完整截图索引。必要私有恢复副本保留在本轮系统临时目录的 0700 子目录，其他内存候选与中间文件已清理。无提交、推送或发布。


## AT-V15 按应用的固定色趋势与恢复复核（2026-11-13）

按用户纠正和 AT-D23，趋势改为一条固定蓝色汇总虚线／淡面积，以及各应用各自固定色的线与图例；时间标签保持系统语义色。复用已含应用标识的时间桶 summary，不增加查询；最多显示时长最多的 6 个应用，并提示汇总包含全部应用，同名应用分别聚合并区分图例。SDK 与宿主用 `lineChartSeries` 协商，旧宿主保留原单汇总线；各列须与总列时间标签逐项对齐，最多各 64 点。会话时间线与应用排行继续顺序多色。

原生夹具已实际查看浅色、深色及 400pt 英文面板，显示蓝色汇总、紫／粉应用线和同色图例，横轴文字无轮换颜色；纵向会话节点多色，截图按会话排列。这些图明确标为合成夹具，使用正式渲染器、不激活应用，不代替实机。首次正式面板打开时发生图例 LazyVGrid 的 SIGTRAP，首帧 `specialized HVGrid.minorGeometry(updatingSize:)`，对应诊断文件为 `Switchly-2026-11-13-141704.ips`，PID 39134。按 AT-D24 改用有界普通纵向图例并补完整数量夹具，不能把首次两个样例的渲染通过写成实机通过。

本轮还发生 AT-INC02：为补真实清除确认图再次触发清除。已用 350 条基线及清除后 6 条数据恢复，原 331 条及 3 张原图一致；但至少 2 条本轮新生成区间未完整恢复，第 4 张旧原始 JPEG 也仍缺失。详见[事故记录](activity-tracking-incident-2026-11-13.md)。新的[正式清除画面](activity-timeline-assets/consent-clear-live-2026-11-13.png)是空输入／清除禁用的有效图，仅说明布局；该画面不证明清除流程安全。后续按 AT-D22／AUTO-D05 禁止对真实库打开清除确认。根因与数据缺口未解决，完整正式验收继续不通过。

最终验证及看图清单由[机器可读证据](activity-timeline-assets/app-series-evidence-2026-11-13.json)记录；恢复数据仍在系统临时目录的私有恢复子目录保全，仓库不保存完整活动历史。未提交、推送或发布。


### AT-V15 最终复核

- 图例改为普通纵向列表后再次执行 `make build`、`make test-unit` 和探针构建：938 项、9 项既有可选场景跳过、0 失败，`TEST SUCCEEDED`。外仓 `npm test` 79/79，`npm run build` 通过；宿主锁更新仅活动插件摘要改变。SDK 14/14（使用本机已有 TypeScript，包含打包后类型检查）、CLI 73/73、Worker 回归通过；契约／共享源码守卫通过，签名深度严格校验通过。`./verify.sh` 为 0 失败、2 项既有警告；两仓 `git diff --check` 通过。
- 已实际查看最终普通图例的浅／深色、400pt 英文及 7 个应用的浅色／窄深色合成图，满数量图例不重叠，截取说明可见。随后正式固定副本成功打开，本机私有图证 `app-series-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）可见汇总及 6 条应用线；日／月切换与滚动正常，本机私有图证 `multicolor-timeline-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）可见 6 个顺序色节点。该图例崩溃场景复验通过，未再发生同类崩溃。
- [恢复后 3 张真实截图](activity-timeline-assets/restored-three-photos-live-2026-11-13.png)已在正式面板显示；未在当前会话页匹配时各自按截图时间独立排列，没有猜测会话关联。结束时恢复日视图。
- 最终只读数据复核：原 331 条逐字段一致、3 张原图逐字节一致、截图索引 3 条、外观／采集设置及插件授权未变；当次库为 412 条（正常采集会继续增长）。第 4 张旧 JPEG、至少 2 条本轮新增区间及清除确认未知根因仍未解决，完整正式验收仍不通过；此次图表复验通过不得覆盖事故结论。
- 共享渲染 revision 为 `sha256:da8626bc10f3f3801761c86d4c643cd2646143e6c406b4937d61545f45d01149`，SDK 契约哈希为 `sha256:3232f69f69becf3125f399abf8693a31dfc3f6d132f2b4d7e173903aa05332a9`。旧视觉基线因 revision 改变失效，本轮生成并查看上述证据，未声称旧基线仍兼容。
- 对照根目录 §8 和通用交付清单核对：范围／契约、构建测试、真实看图、数据及设置复核已附证据；未通过项为事故恢复缺口、确认安全根因及原状态栏直接点击证据。必要恢复目录继续以 0700／0600 保留，其余本轮临时产物清理；未提交／推送／发布，既有未提交修改保留。


## AT-V16 会话页截图范围与亮暗映射核查（2026-11-13）

- 问题：会话页和截图页独立读取全范围，切换会话页时会重复混入同一张较新的独立截图，造成“每页末尾都是最新截图”的表现。按 AT-D25 修正：先读取当前会话页，再按该页最早开始到最晚结束查询截图；会话翻页重置截图游标。没有会话时保留独立图片降级，不以时间猜测 sessionID。
- 正式副本：工作区 `DerivedData/Build/Products/Debug/Switchly.app`，最终启动 PID 19430。退出旧实例前保留私有数据基线，构建和测试完成后启动，最终停留日视图。本轮没有打开清除确认、改动采集设置或系统权限。
- 正式看图：第一页为 09:37:08～09:42:33，会话第二页为 09:42:33～09:46:26；均只展示该页会话，明确“当前会话页没有截图”，没有附上今天下午的新截图。见 本机私有图证 `session-page-one-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）、本机私有图证 `session-page-two-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）。
- 仍存在的分页限制：持续采集触发 revision 变化时，旧游标会按 AT-D18 失效并提示“活动记录已更新，已回到第一页”；实机观察到第二页成功后又回第一页。因此此阶段截图范围修正已验证，持续采集下稳定浏览历史当时未通过；该问题随后按 AT-D26 修正并由 AT-V17 复验。
- 原生合成夹具：两个截图均归入明确匹配的会话，中间会话没有图片；已实际看图，见 [深色夹具](activity-timeline-assets/session-scoped-timeline-dark-fixture-2026-11-13.png)。它不是新的真实采样证据。
- 截图为什么稀疏：记录和截图不一一对应，采样要求允许名单、前台至少 30 秒、有效辅助功能／录屏权限、每应用成功采样后至少 600 秒冷却、全局尝试间隔至少 30 秒；截图默认 7 天，会话保留 400 天。不能把不满足条件与既有事故缺图混为一谈。
- 数据只读复核：重启前 464 条会话／6 JPEG。复核时 477 条会话／7 JPEG，基线 464 个 ID 全保留；一个原 checkpoint 在正常退出时结束为 disabled，属于现有退出封口流程。基线 6 JPEG 的 SHA-256 全一致；当前 7 张图片均有会话和文件。旧事故中缺失的一张原始 JPEG 和至少两条新增区间未在本轮找回，不能宣称历史已完整恢复。私有基线与完整审计保留在原恢复目录的 `page-followup-2026-11-13/`，不迁移原始活动 JSON 到仓库。
- 亮暗映射：AppTheme.light→aqua／light，dark→darkAqua／dark，双语 Light／Dark 文案无反置；正式偏好设置实图为暗色选中且深色内容。StatusBarController 使用模板图（isTemplate=true、contentTintColor=nil），意图由系统菜单栏外观着色，与应用界面主题不是同一个设置。ThemeApplier 对 NSApp.windows 的全量应用仍值得复核，但没有有效的状态项截图支持根因判断，本轮未改此实现。
- 图标实机限制：SystemUIServer 连接报 `timeoutReached`；主屏菜单栏裁切只有背景、未含目标状态项。不能据此认定图标已正确着色，也不能凭现象把亮／暗枚举交换。状态图标本体的亮暗对照仍未验。
- 门禁：外仓 npm test 80/80，npm run build 通过；宿主 make build 通过，make test-unit 执行 938 项、9 跳过、0 失败、TEST SUCCEEDED；Probe 构建／隐藏原生渲染通过；codesign --verify --deep --strict 通过；verify.sh 为 0 失败／2 既有警告；两仓 git diff --check 通过。插件锁仅接受活动插件的新摘要，不提交／推送。
- 自检：按项目 AGENTS 第 8 节与通用 delivery-checklist 核对范围、双语、代码／测试、看图与数据保全；已完成的分页截图修正有证据，未通过项明确为菜单栏图标实色对照、持续采集下稳定浏览和既有恢复缺口。调试目录在日志与精选看图证据迁出后清理；必要私有恢复材料继续保留。


## AT-V17 持续采集时保留历史页（2026-11-13）

- 承接 AT-V16 的实机失败继续修正：ActivityDataProvider 的游标增加采集代次／已读前缀 SHA-256 校验，摘要由后台任务计算，不再单凭全局 revision 拒绝游标。旧前缀不变时尾部追加可继续；已读记录被修改、删除、插入、裁剪，查询变化或清除换代仍拒绝。没有缓存整份查询或放宽权限。
- 新增隔离库测试 `testSessionCursorSurvivesTailAppendButRejectsChangedPrefixAndQuery` 与 `testSnapshotCursorSurvivesTailAppendButRejectsDeletedPrefix`：真实正式存储／Provider 验证追加＋revision 增长后的翻页、查询变化、已读会话修改、清除换代和已读截图删除。测试清除只针对临时目录。
- 最终工作区副本 PID 65657，构建、测试、签名完成后启动，之后不再构建覆盖。真实采集开启时第 2 页维持同一组 09:42:33～09:46:26 会话；两次正式看图间隔 48.6 秒，汇总与库内尾部持续增长，之后成功进入第 3 页 09:46:26～09:49:03。没有回到第 1 页，也没有混入下午截图。图证：本机私有图证 `stable-page-two-before-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）、本机私有图证 `stable-page-two-after-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）、本机私有图证 `stable-page-three-live-2026-11-13.png`（含真实应用使用历史，未随公开仓库上传）。最终面板保留日视图第 3 页。
- 最终门禁：make build 通过；make test-unit **940 项，9 跳过，0 失败，TEST SUCCEEDED**；Worker tests passed；契约／35 核心类型／renderer revision 守卫通过；codesign 深度严格校验通过；verify.sh 0 失败、2 既有警告；外仓最终插件代码仍是 80/80 测试和构建通过的版本；两仓 diff --check 通过。
- 契约公开文档与 capabilities 错误说明同步，sdkContractHash 更新为 `sha256:b748c257e61bf5c5a4439f775720ca215da30bdffd2ac933a579bc3922681c5a`；rendererRevision 不变。
- 第二次构建前 483 条会话的 ID 全部保留，7 张基线 JPEG 字节一致；最终只读审计时 489 条会话、7 张截图，图片均有对应会话和文件。旧事故缺口未被这次修正补造或宣称恢复。私有备份／日志保留在既有恢复目录，调试工作目录清理。
- 自检签署：按项目 AGENTS 第 8 节及通用 delivery-checklist 核对，分页两项问题已有真实图证与回归；菜单栏图标实色对照与旧恢复缺口仍未通过，因此不报告完整项目验收全部通过。未提交或推送，保留两仓已有修改。
