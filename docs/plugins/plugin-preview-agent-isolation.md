# 插件预览的 Agent 验证隔离方案

日期：2026-11-03。状态：方案建议；本次仅接入预览 App 图标，以下隔离行为尚未实现，不覆盖现有截图契约。

## PV-D01：分开处理不抢焦点、不遮挡与桌面隔离

依据：`Tools/PluginPreview/Entry/PreviewAppMain.swift` 的启动路径对 `dev`、`run` 均执行 `makeKeyAndOrderFront` 与 `NSApp.activate(ignoringOtherApps: true)`；截图路径另外创建窗口并再次 `makeKeyAndOrderFront`。因此当前自动化运行会主动切走用户焦点，并显示两个窗口。

“不抢焦点”不等于“不遮挡”。仅删除 activate 或改成 `orderFrontRegardless`，仍可能把预览盖在用户工作窗口上，不能作为最终验收结论。当前截图使用真实 WindowServer 窗口和 `screencapture -l`；真实窗口不意味着必须成为 key 或位于最前，但非前台、遮挡和隐藏时的截图完整性必须分别实测。

影响面：后续 T08/T09/T16/T19 的预览窗口策略与验证环境，不改变正式宿主。

## 路线与推荐顺序

| 路线 | 适合的验证 | 对当前桌面的影响 | 边界 |
| --- | --- | --- | --- |
| 无 GUI worker | JS、动作、时间推进、输出树、错误分支 | 不创建原生窗口 | 不证明视觉或原生输入通过；复用现有 worker/验证器 |
| 后台原生截图 | 共享 SwiftUI/AppKit 的布局和普通材质截图 | 目标是不激活、不提到前台 | 需先证明窗口被遮挡时仍完整截图；仍依赖 GUI 会话与捕获权限 |
| 独立 macOS 虚拟机或专用 GUI runner | 原生截图、可访问性 press、后续真实鼠标键盘测试 | 测试窗口在独立桌面内 | 保留原生渲染；系统版本、分辨率、缩放与权限必须记录，结果只覆盖该环境 |
| 手动分配另一个 Space | 临时减少干扰 | 仍共享应用激活与输入会话 | 可受切换应用时切换 Space 的系统设置影响；不作为隔离保证 |

推荐：日常逻辑回归走 worker；先验证后台原生截图作为低成本改进；需要保证不打扰时，将完整视觉与交互回归放进独立 macOS GUI 环境。Agent 直接读取该环境输出的 PNG 和报告，可另做查看器展示，查看器不重写原生渲染器。

浏览器的独立页面可以承载结果查看，但不能直接隔离外部 AppKit 窗口。将原生界面重写成网页会引入另一套渲染器，不纳入本方案。T01 已记录 ImageRenderer 的进度条异常，因此目前不将其用于权威视觉基线，也不承诺无 WindowServer 的完整原生无头验收。

## 后续任务与可检查验收

1. **PV-T01（当前环境验证通过，见 PV-D04）— 后台截图探针**：先复用 T01 渲染内容，分别测试普通与玻璃材质在非 key、后置且被遮挡时的捕获。以合成背景窗口避免捕获用户内容。记录运行前、中、后的前台应用是否变化；检查 PNG 的控件、图片、Scene 和尺寸。验证失败明确返回环境错误，不自动回退到抢前台截图。
2. **PV-T02（依赖 PV-T01，待实施）— 分离 dev/run 窗口策略**：dev 保留显式打开的交互窗口；自动化 run 不主动激活 App，不展示工作台，只创建经验证所需的渲染表面。进程内可访问性 press 独立验证，不把它表述为全局鼠标键盘测试。参数、报告和错误语义先同步契约，再实现与 CLI 测试。
3. **PV-T03（待环境选型）— 独立 GUI runner**：提供固定系统、分辨率、缩放与合成桌面背景，单次运行单个视觉任务；输出既有 report.json、preview.png、ui-tree.json、actions.json。宿主侧实测运行期间无前台变化、无弹窗覆盖，另验 runner 内截图和输入。保留正式宿主 Dock/AX/跨屏的实机验收。

上述任务尚未执行，不将方案或静态代码检查计为隔离验证通过。

## PV-D02：预览 App 独立图标

日期：2026-11-03。结论：使用做图工具生成“玻璃预览窗口＋插件拼图＋播放符号”，青色底板与宿主关联；资源独立放在 `Tools/PluginPreview/Resources/Assets.xcassets`，只接入预览 target，不改变宿主 AppIcon。

依据与检查：`project.yml` 配置 `PreviewAppIcon`；执行 `make plugin-preview-app` 后核对产物 Info.plist 的 CFBundleIconName/CFBundleIconFile 与实际 icns。检查源图、大/小尺寸和编译后的图标；构建与实际读图结果以本次交付记录为准。

本次实测：`make plugin-preview-app` 退出 0；Info.plist 两个图标字段均为 `PreviewAppIcon`，资源目录存在 `PreviewAppIcon.icns`；已实际读取生成图、128px 资源和从 icns 解出的图像，窗口、拼图及播放符号可见。资源含 16/32/64/128/256/512/1024px 七档 PNG、十个 macOS 图标槽位。`./verify.sh` 输出 `PASS 0 check(s) failed, 2 warning(s)`（工作区未提交修改、已有超长文件）；Xcode 另报 CoreSimulator 版本不匹配诊断，macOS 构建仍成功。未启动预览 App，Dock/Finder 的运行时缓存刷新未验证。未修改 Swift 逻辑，未重跑宿主单元测试。


## PV-D03：基础遮挡探针实测（2026-11-03）

基础 AppKit/SwiftUI 合成窗口三次运行通过：窗口后置、不 makeKey、不激活，在浮动蓝色合成遮挡窗覆盖时按窗口 ID 捕获。三次均 capture_status=0；PNG=480x560、red=96000、blue=0、transparent=0，前台应用在每次运行前、中、后保持一致。主控实际读图确认红黄内容完整，未混入蓝色遮挡层。

此结果仅证明基础窗口捕获可行，不证明真实插件共享 Renderer、玻璃材质及 nativeClick 回归通过。PV-T01 状态为部分完成，PV-T02/PV-T03 未放行。执行者还报告 make plugin-preview-app 退出 0，但没有完成修改后真实 run 的端到端验证，因此未保留窗口策略变更。当前未启用后台运行模式。临时探针与截图复核后清理。


## PV-D04：共享 Renderer 后台遮挡捕获（2026-11-03）

本条更新 PV-D03 的“共享 Renderer 尚未验证”状态；PV-D03 的历史基础探针证据保留。执行 `./Tools/PluginPreview/run-t01.sh --background`，退出 0：plain_status=0、glass_status=0、core_window_capture=PASS。两种模式均输出 background_occlusion=PASS、background_frontmost_during=unchanged、background_frontmost_after=unchanged。窗口列表确认浮动合成遮挡窗口在目标前且 frame 完全覆盖，未调用 makeKey/activate。

环境为 arm64、macOS 27.0.1、主屏 1920×1080@2x、两屏、屏幕捕获预检 true。两张原生截图均为 1212×1612；plain red=29447/yellow=29082/cyan=39391，glass red=29455/yellow=29096/cyan=48263。主控实际读图：原生按钮、toggle、slider、progress，artwork、插件条纹资产与 Scene 图片均可见，未发现空白、漏层或裁切。玻璃有蓝灰材质层；不将其作为逐像素稳定基线。

PV-T01 在上述环境的普通与玻璃共享渲染捕获验证通过。前台检测是捕获前、中、后的采样，不是连续事件审计；探针有意短暂显示合成遮挡窗，因此不代表零桌面干扰。未验证其他系统/架构/Space、无捕获权限、无 GUI、真实插件动作或 nativeClick；这些不因本探针通过而视为完成。PV-T02/PV-T03 尚未实施，正式 run 行为未改。

回归检查：`make build` 退出 0；`make test-unit` 退出 0，Executed 551 tests, with 8 tests skipped and 0 failures；`git diff --check` 通过。本轮只改探针、脚本及说明，保留此前 PV-D03 文档修改。主控读图后已清理本轮截图、探针产物和临时构建/测试日志。


## PV-D05：PV-T02 首轮集成未通过（2026-11-03）

尝试将 run 改为 accessory、不激活/隐藏工作台、截图 orderBack。`make plugin-preview-app` 退出 0；`Tests/PluginPreview/run-baseline-tests.sh` 全部通过（重复截图差异像素为 0、插件改动被检出、玻璃拒绝基线）。但 `Tests/PluginPreview/run-native-input-tests.sh` 失败：positive、disabled-click、not-disabled、wrong-action 四项均得到 element-not-found；missing 负向项通过。

补充实验包括显式 layout/display、透明后置工作台、离屏工作台、仅插件表面的后置窗口、重新创建 hosting；均未恢复 nativeClick。这些尝试只支持“后台窗口的 SwiftUI 可访问性节点不可按原路径定位”这一现象，不足以断言框架根因或证明必须激活。不得增加重试、将动作直调冒充原生输入，或自动回退到抢前台。

已撤回本轮所有运行态和候选契约改动，重新构建退出 0，并复跑原实现原生输入：positive/disabled-click/not-disabled/missing/wrong-action 五项全部 PASS。PV-T02 未完成、不放行；正式 run 仍为原行为，既有 PV-T01 改动保留。本轮临时构建日志已清理。

下一排查应对相同内容、相同窗口依次单独改变 activation policy、是否激活、是否 key、ordering、occlusion，记录可访问树节点数及生命周期；每个变量独立对照，先定位触发条件再改实现。此项未执行；PV-T03 的独立 GUI runner 仍可承载现有原生输入验证，但尚无已验环境。
