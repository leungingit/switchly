# Switchly — Agent 工作约定

本文件适用于整个仓库。默认使用中文沟通；代码标识符沿用英文，用户可见文案同时维护英文和简体中文。遵循系统、开发者和用户的明确指令，以及适用的全局与子目录约定。

## 1. 项目与阅读入口

Switchly 是完全本地运行的 macOS 菜单栏窗口预览与切换工具，使用 Swift 5.9、SwiftUI / AppKit 和 MVVM。最低运行系统为 macOS 12；构建需要 Xcode 26+，因为材质实现使用 macOS 26 SDK，并为旧系统提供降级。

开始修改前按任务阅读：

- [README.md](README.md)：产品能力、权限、构建与签名概览。
- [CONTRIBUTING.md](CONTRIBUTING.md)：开发、设置兼容、日志、测试约定。其 Xcode 15+ 描述已落后于 README 和当前 SDK 要求，构建采用 Xcode 26+。
- [project.yml](project.yml)、[Makefile](Makefile)：工程配置与可执行命令的真源。
- [PRIVACY_POLICY.md](PRIVACY_POLICY.md)：本地处理与隐私边界。
- [docs/RELEASING.md](docs/RELEASING.md)、[CHANGELOG.md](CHANGELOG.md)：发布流程与变更记录。
- 涉及视觉方向时，阅读 [docs/design-system.md](docs/design-system.md) 与 [docs/ui-guidelines.md](docs/ui-guidelines.md)，并对照当前共享视觉实现；用户确认的设计意图、当前实现及历史差异已迁入正式文档，过程草稿不能自动覆盖。

文档与代码不一致时，先查清真实行为和用户意图，明确应修正哪一方，再同步相关内容。不得通过只改文档掩盖实现缺陷，也不得静默改变既有契约。

## 2. 范围与工作区

- 先检查 `git status --short`，保留用户已有修改和未跟踪文件；只修改本次任务所需内容，不顺手重构、格式化或清理其他模块。
- 排障先沿日志、运行产物、持久化数据和真实系统调用定位原因，再做最小修复；不得用增加重试掩盖尚未定位的错误。
- 复用已有类型、服务协议、匹配规则、设置入口和设计令牌，禁止另造同用途的平行实现。
- 新增依赖必须有具体必要性，优先使用系统框架和现有依赖；需要新增时说明代价并遵循 CONTRIBUTING 的讨论要求。
- 根目录 `work/` 为 Git 忽略的本地临时目录，不提交；设计过程资料在必要规则与资产迁入正式文档后可以清理。
- 调试截图、临时脚本和日志放在系统临时目录的任务子目录；正式测试夹具、设计资产和项目约定的构建输出按现有位置保存。只清理本次创建且已不再需要的临时文件。
- 不因验证失败回滚用户修改；只修正本次引入的问题。提交、推送、打标签和发布按用户授权范围执行。

## 3. 架构与依赖边界

本项目没有 Web 前后端；对应的工程边界是界面层与本地服务层。

| 目录 | 职责与约束 |
| --- | --- |
| `App/` | 生命周期、菜单栏、服务装配与跨模块协调；避免继续堆积可独立测试的业务逻辑 |
| `Models/` | 数据结构、枚举、设置与业务规则；不得依赖 Views / ViewModels 或驱动界面生命周期 |
| `ViewModels/` | 交互状态、筛选、服务编排；通过服务协议注入依赖，避免直接操作 AX / CG 底层窗口接口 |
| `Views/` | SwiftUI 视图、AppKit 面板与展示桥接；负责展示和输入，不直接编码持久化、窗口枚举或截图业务 |
| `Services/` | AX 权限与窗口操作、窗口监控、缩略图、快捷键、设置、统计；不得反向依赖具体 Views / ViewModels |
| `Utilities/` | 共享设计、动效、日志、图标缓存和窗口匹配工具；保持职责明确，避免成为业务杂物箱 |
| `Resources/` | Info.plist、资源和双语文案 |
| `Tests/` | 单元、快照与 UI 测试；系统行为仍需真实运行验证 |

- 新服务定义 `protocol`，通过初始化参数注入依赖，便于使用 fake 验证行为；不要在新逻辑中散布 `.shared`。
- AppKit 面板允许管理自身窗口与事件，但业务动作委托 ViewModel / Service。现有跨层调用不构成新增跨层依赖的理由；不要求为局部任务重写全库。
- 窗口归属与匹配优先复用 `WindowMatchRules`、`WindowAttribution` 和现有 Accessibility 实现，保留解释平台行为的注释。
- 类型尽量一文件一个，文件尽量控制在约 500 行内；拆分应服务于职责和可测试性。

## 4. 界面与视觉约束

- 间距、圆角、细边框复用 `Utilities/DesignTokens.swift`；动画复用 `MotionTokens.swift`；玻璃、卡片与面板材质复用 `GlassEffect.swift`，macOS 26+ 原生透明容器复用 `NativeCrystalContainer.swift`；主题应用复用 `ThemeApplier.swift`。
- 新增共用视觉值集中到对应令牌或材质实现。优先系统语义色，避免在各个 View 中新增散落的 Hex / RGB、阴影、透明度或动画时长；已有局部值仅在任务涉及时收敛。
- 保留 Switchly 已有视觉语言。参考其他仓库的是工程约束，不移植其白卡、四角括号、禁用全部阴影或特定字体等产品风格。
- 透明度必须同时检查 NSWindow / NSPanel 背景与 SwiftUI 内容背景，不能仅让窗口透明却保留不透明内容层。
- 外观设置应贯通模型、默认值、编辑、保存、变更通知和实际运行面板。预览、Dock 预览、Workspace 等共享外观应复用统一设置来源，不另设重复开关。
- 布局按目标屏幕的 `visibleFrame` 约束，处理多显示器、长标题、空状态和内容溢出，避免固定宽度导致遮挡或越界。
- 覆盖浅色、深色、跟随系统和所涉及的玻璃开关状态；新系统 API 必须有可用性检查和 macOS 12 降级。
- 动画遵循系统“减少动态效果”；交互控件提供可理解的标签、键盘路径和焦点反馈，不能仅靠颜色传达状态。
- 所有新增用户文案维护 `Resources/en.lproj/Localizable.strings` 与 `Resources/zh-Hans.lproj/Localizable.strings`，复用已有本地化方式；错误提示应可理解，技术细节留在日志。

## 5. 服务、并发与性能约束

- UI 绑定状态与 AppKit 窗口操作在主线程执行，通过 `@MainActor` 或明确的主队列切换保证；不要在后台直接更新可观察界面状态。
- 截图、批量窗口扫描、文件 I/O 和高开销计算避免阻塞主线程。AX 调用遵循现有线程与超时约定，不可机械地搬到任意后台队列。
- 锁内只读写受保护状态；先复制快照并解锁，再通知观察者、执行回调或耗时系统操作。
- `Task`、Timer、NotificationCenter / Combine 订阅、事件监听和截图刷新客户端都要有明确所有者与停止路径；关闭面板、切换目标或停止服务时取消、退订或释放，重复 start / stop 应安全。
- 异步返回前检查取消和目标是否仍有效，避免旧窗口结果覆盖新状态；不使用无边界的重试、队列、缓存或后台轮询。
- 缩略图与窗口监控复用已有缓存、刷新兴趣和预算机制，避免多个面板重复抓取同一窗口；设置读取不应在热路径重复解码。
- 系统调用失败要区分权限不足、窗口已关闭、匹配失败和聚焦失败。不能把“应用已激活”当成“目标窗口已聚焦”。
- 新增设置同步修改 `AppSettings`、默认值、解码、设置 UI 与消费方；可选新增字段使用 `decodeIfPresent` 加合理默认值，保留旧数据与旧键迁移兼容。
- 设置持久化复用 `SettingsService`，保持 `com.switchly.settings` 与现有 `com.windowsnap.settings` 读取兼容；保存后更新缓存并通知运行态消费方，不在 View 中另写 UserDefaults。

## 6. 权限、隐私与系统排障

- 保持完全本地处理，不新增网络能力、遥测、分析 SDK、账户或在线授权检查；**唯一例外**是用户显式开启的在线天气（`OnlineWeatherService`：仅 HTTPS GET 天气服务、每 15 分钟最多一次、默认关闭、密钥不入日志、插件只读宿主快照），改动该例外需同步 `PRIVACY_POLICY.md` 第一章；小尺寸缩略图仅在本地缓存，按原始截图时间最多复用 24 小时，磁盘总量不超过 64 MB；不保存放大预览原图、不上传。身份校验包含系统启动会话、目标应用进程启动时间、窗口 ID 和标题摘要；启动及写入时清理过期文件，读取时拒绝并删除过期文件。新增统计保持本地存储与可清除。
- 保留 Info.plist 的权限用途说明。屏幕录制权限缺失时保持图标与标题降级；Accessibility 权限与 Screen Recording 权限分别判断和提示。
- 不为“修权限”随意开启 App Sandbox 或增加 entitlements。确需变更时先验证 AX 枚举、截图、快捷键及发布签名的影响。
- `project.yml` 是工程与 entitlements 配置真源，调整后用 `make generate` 或 `make bootstrap` 生成，审查生成差异；禁止只手改 `project.pbxproj` 或被生成覆盖的 entitlements。
- 签名私有配置留在忽略的 `Config/Local.xcconfig`，不提交证书、Team ID、密钥或用户机器配置；默认配置沿用 `Config/Base.xcconfig`。
- 使用 `AppLogger` 记录关键流程，保留已有诊断能力，采用 `key=value` 字段；避免记录不必要的窗口标题、用户路径或其他敏感内容，分享日志前脱敏。
- AX / 切窗异常先确认正在运行的 bundle 路径、签名和最终 entitlements，再对照日志中的 PID、windowID、AX 返回码与 focused window。不要混测 `build/`、`DerivedData/` 和 `/Applications` 的不同副本。
- 日志位置以 `AppLogger.logFileURL` 为准；普通非 sandbox 构建为 `~/Library/Logs/Switchly/Switchly.log`。文件日志默认关闭，需在「偏好设置 → 常规 → 写入本地日志文件」开启后才会写入。重建签名变化也可能影响系统权限识别。

## 7. 常用命令与验证

以下命令均从仓库根目录执行，以 Makefile 的当前定义为准：

```sh
make help          # 查看实际支持的目标
make bootstrap     # XcodeGen 生成工程（make generate 也可）
make build         # Debug 构建
make test-unit     # 单元测试，跳过 SwitchlyUITests
make test          # 单元 + UI 测试
make run           # 构建并退出旧实例后启动 Debug app，会中断当前 Switchly
./verify.sh        # 工具链、工程、版本、跟踪文件与隐私卫生检查
```

- Debug 产物为 `DerivedData/Build/Products/Debug/Switchly.app`；`make build-release` 不会自动更新 `build/`，分发副本由 `make dist` 或 `build.sh` 生成。
- Swift 代码修改后运行 `make build` 与 `make test-unit`，并补充与风险相称的回归测试；优先覆盖窗口归属、设置旧数据解码、取消、缓存失效和错误分支，不写只复述实现的测试。
- UI 修改必须实际运行并查看相关界面截图，检查布局、遮挡、材质、交互和所涉及的主题状态；不能只凭编译、文本存在断言或未查看的快照宣称视觉通过。几何变化应验证真实边界、间距或重叠情况。
- AX 枚举、同应用切窗、最小化恢复、跨屏定位、Dock 悬停等系统行为需要真实场景验证。单元测试或 UI 测试骨架不能替代系统集成证据。
- 仓库当前没有 `make guardrails` 或 `make ui-preview` 目标，不照搬其他仓库命令，也不声称存在未实现的门禁。
- 纯文档修改检查内容、链接、命令和差异即可，无需构建。环境或权限限制导致无法验证时，明确写出未执行项与原因，不能报告通过。
- 发布、版本修改、打标签按 `docs/RELEASING.md` 执行；`Resources/Info.plist` 是版本真源。不要在普通修复中顺手运行 `make release-*`、`make clean` 或修改版本。

## 8. 交付自检

按本次任务适用项核对，并在交付中说明变更、验证证据和剩余限制；不适用项无需机械填表。

- [ ] 范围明确，未覆盖或清理用户已有修改，未引入重复实现和无关依赖。
- [ ] 界面复用共享令牌与材质，双语文案、主题、减少动态效果和相关布局状态已检查。
- [ ] 服务依赖方向、主线程状态更新、锁边界、取消与退订闭环正确。
- [ ] 新设置兼容旧数据，持久化与实际运行态保持一致；权限缺失有正确降级。
- [ ] 代码构建与适用测试通过；UI 看过真实截图；系统行为有真实验证或明确未验说明。
- [ ] 新增可见能力同步 README 功能说明；架构、命令或约束改变同步本文件，用户行为变更按需补充 CHANGELOG，发布与隐私变更同步相应文档。
- [ ] 最终检查 `git diff --check` 与 `git status --short`，无本次引入的临时文件、构建产物或敏感信息。

本约定参考了全局 Agent 约定入口，以及 oh-my-workers 的 AGENTS、前端和后端规范中关于契约一致性、共享设计、单向分层、并发安全、资源生命周期和证据验收的原则；具体规则与命令已按本仓库的原生 macOS 实现调整，无需依赖外部仓库才能执行。
