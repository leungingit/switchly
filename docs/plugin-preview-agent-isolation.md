# 插件预览的 Agent 验证隔离方案

日期：2026-11-03。状态：方案建议；本次仅接入预览 App 图标，以下隔离行为尚未实现，不覆盖现有截图契约。

## PV-D01：分开处理不抢焦点、不遮挡与桌面隔离

依据：`Tools/PluginPreview/Build/PreviewAppMain.swift` 的启动路径对 `dev`、`run` 均执行 `makeKeyAndOrderFront` 与 `NSApp.activate(ignoringOtherApps: true)`；截图路径另外创建窗口并再次 `makeKeyAndOrderFront`。因此当前自动化运行会主动切走用户焦点，并显示两个窗口。

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

1. **PV-T01（待实施）— 后台截图探针**：先复用 T01 渲染内容，分别测试普通与玻璃材质在非 key、后置且被遮挡时的捕获。以合成背景窗口避免捕获用户内容。记录运行前、中、后的前台应用是否变化；检查 PNG 的控件、图片、Scene 和尺寸。验证失败明确返回环境错误，不自动回退到抢前台截图。
2. **PV-T02（依赖 PV-T01，待实施）— 分离 dev/run 窗口策略**：dev 保留显式打开的交互窗口；自动化 run 不主动激活 App，不展示工作台，只创建经验证所需的渲染表面。进程内可访问性 press 独立验证，不把它表述为全局鼠标键盘测试。参数、报告和错误语义先同步契约，再实现与 CLI 测试。
3. **PV-T03（待环境选型）— 独立 GUI runner**：提供固定系统、分辨率、缩放与合成桌面背景，单次运行单个视觉任务；输出既有 report.json、preview.png、ui-tree.json、actions.json。宿主侧实测运行期间无前台变化、无弹窗覆盖，另验 runner 内截图和输入。保留正式宿主 Dock/AX/跨屏的实机验收。

上述任务尚未执行，不将方案或静态代码检查计为隔离验证通过。

## PV-D02：预览 App 独立图标

日期：2026-11-03。结论：使用做图工具生成“玻璃预览窗口＋插件拼图＋播放符号”，青色底板与宿主关联；资源独立放在 `Tools/PluginPreview/Resources/Assets.xcassets`，只接入预览 target，不改变宿主 AppIcon。

依据与检查：`project.yml` 配置 `PreviewAppIcon`；执行 `make plugin-preview-app` 后核对产物 Info.plist 的 CFBundleIconName/CFBundleIconFile 与实际 icns。检查源图、大/小尺寸和编译后的图标；构建与实际读图结果以本次交付记录为准。

本次实测：`make plugin-preview-app` 退出 0；Info.plist 两个图标字段均为 `PreviewAppIcon`，资源目录存在 `PreviewAppIcon.icns`；已实际读取生成图、128px 资源和从 icns 解出的图像，窗口、拼图及播放符号可见。资源含 16/32/64/128/256/512/1024px 七档 PNG、十个 macOS 图标槽位。`./verify.sh` 输出 `PASS 0 check(s) failed, 2 warning(s)`（工作区未提交修改、已有超长文件）；Xcode 另报 CoreSimulator 版本不匹配诊断，macOS 构建仍成功。未启动预览 App，Dock/Finder 的运行时缓存刷新未验证。未修改 Swift 逻辑，未重跑宿主单元测试。
