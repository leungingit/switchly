# 插件预览的 Agent 验证隔离方案

日期：2026-11-03，更新至 2026-11-10 PV-D14。状态：PV-T01 已验证；PV-T02 的后台截图、标签输入与 SceneKit 坐标输入已正式接入并通过本机回归；跨系统等发布矩阵未完成；PV-T03 待独立环境。

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
2. **PV-T02（本机接入与限定输入通过，见 PV-D14；发布矩阵未完成）— 分离 dev/run 窗口策略**：dev 保留显式打开的交互窗口；`run --background` 使用从不排序的原生面板，支持 AX 标签 press 及真实 SceneKit 视图坐标点击／拖动，不发送全局键鼠。旧系统、Intel、跨 Space、压力及完整输入未验。
3. **PV-T03（待环境选型）— 独立 GUI runner**：提供固定系统、分辨率、缩放与合成桌面背景，单次运行单个视觉任务；输出既有 report.json、preview.png、ui-tree.json、actions.json。宿主侧实测运行期间无前台变化、无弹窗覆盖，另验 runner 内截图和输入。保留正式宿主 Dock/AX/跨屏的实机验收。

上述状态以各条实测记录为准，不将方案或静态代码检查计为隔离验证通过。

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

下一排查应对相同内容、相同窗口依次单独改变 activation policy、是否激活、是否 key、ordering、occlusion，记录可访问树节点数及生命周期；每个变量独立对照，先定位触发条件再改实现。此项未执行；PV-T03 的独立 GUI runner 仍可承载现有原生输入验证，但尚无已验环境。本条关于“尚无后台 `run` 路径”的状态被 PV-D06 取代；nativeClick 失败结论保留。

## PV-D06：显式后台截图路径（2026-11-05）

本条更新 PV-D05 的“PV-T02 尚未接入”状态，保留其 nativeClick 失败结论。`run --background` 使用 accessory 激活策略，不创建工作台窗口；截图表面 `orderBack`，不调用 `makeKeyAndOrderFront` 或 `activate`。含 `nativeClick` 的场景在执行前返回 `unsupported`，不以业务动作直调冒充原生输入；默认 `run` 与 `dev` 的原行为保留。参数及错误语义见 [预览契约](plugin-preview-contract.md) §3。

环境为 arm64、macOS 27.2.0、GUI 会话、显示缩放 2、已有屏幕录制授权。`make plugin-preview-app`、`make plugin-preview-worker`、`make build` 退出 0；`make test-unit` 退出 0，xcresult 汇总 543 passed、8 skipped、0 failed；`node --test Plugins/cli/test/preview.test.js` 28 项通过。`Tests/PluginPreview/run-baseline-tests.sh` 的首次截图、重复截图差异 0、插件内容变化检出、真实玻璃表面截图与玻璃基线拒绝均通过。单独执行 `run --background`：普通截图退出 0、报告 `passed`、PNG 存在；`expectText → action(go) → expectText` 三步全部 passed；含 nativeClick 的原夹具退出 3，报告 `unsupported/unsupported`；普通截图调用前后采样的前台 PID 均为 1397。主控实际读取普通截图，文字及三个原生控件可见。

玻璃核验中，原夹具只含 vstack，无玻璃表面；将其场景环境改成 glass 后，PNG 与普通图 SHA-256 完全一致，不能当作真实玻璃覆盖。随后在系统临时目录复制该夹具并以真实 `surface(material: glass)` 包裹相同控件，`run --background` 退出 0，主控读图确认浅蓝玻璃底层、文字和按钮可见。回归脚本已加入真实玻璃表面与普通截图像素差异检查。此证据覆盖当前环境的截图结果，不覆盖跨 Space、无 GUI、无授权、连续焦点事件、遮挡边界或原生输入隔离。

`make plugin-preview-package` 退出 0，契约哈希、渲染器 revision 和共享源码守卫通过。首次执行 `Tests/PluginPreview/run-guide-check.sh` 因脚本仍指向旧的 `docs/plugin-preview-guide.md` 路径而退出 1；修正为 `docs/plugins/plugin-preview-guide.md` 后重跑，quickstart 与 agent-loop 原样执行均 PASS，结尾为 `SUMMARY guide passed`。`./verify.sh` 为 `PASS 0 check(s) failed, 2 warning(s)`（工作区改动与已有超长 Swift 文件）；`git diff --check` 通过。

本机 `prlctl list -a -o name,status` 仅列出已暂停的 Windows 11，`limactl list --json` 无实例，当前无可用的 macOS GUI runner。下一步仍需在独立 GUI 环境对同一工作台逐项测试 activation policy、激活、key、ordering、occlusion 与可访问树节点数，之后才可判断 nativeClick 是否能走后台路径；PV-T03 尚未放行。

## PV-D07：合成界面的后台输入对照（2026-11-10）

独立合成 SwiftUI／AppKit 探针中，外部系统 AX 能发现原进程内驱动遗漏的后台节点，并真实触发按钮和开关；仅外部只读遍历也使随后进程内 SwiftUI 枚举从 `notFound` 变为 `pressed`。指定窗口的原生坐标事件在没有外部 AX 初始化时也能操作本例按钮和开关。屏幕内后置与屏幕外窗口均验证，禁用按钮回调均为 0，未观察到前台应用切换；补充轮次未发生窗口成为 key。

多轮指针采样存在变化且未记录事件来源，不能宣称全部零指针干扰。未覆盖真实共享 Renderer、3D、键盘或完整交互隔离。细节、实际输出、视觉核验与未完成项见 [实验记录](../../reviews/plugin-preview/plugin-preview-background-input-2026-11-10.md)。PV-D05 的历史失败保留；PV-D06 的后台截图契约不变；本条补充新的可行性证据，优先推进真实 Renderer 的本机定向输入对照，PV-T02 原生输入及 PV-T03 均未放行。

## PV-D08：真实 Renderer 输入通过，完全屏幕外捕获未通过（2026-11-10）

真实共享 `PluginSlotSurface`／`PluginOverlayView` 和预览 worker 会话中，外部只读 AX 后原驱动、外部 AX press、指定窗口坐标事件均通过原 7 步 2D 场景；AX 与坐标通道的原有负向场景 8/8 符合预期。真实 iPod 3D 插件的 AX `Play/Pause` 节点缺失，但 SceneKit 几何坐标事件能触发 `toggle`，3/3 步通过；主控查看后台窗口截图确认暂停符号变为播放符号。若干成功轮次连续监测到前台不变、指针位置不变、无全局鼠标移动事件。

本条取代 PV-D07 中未经实际 frame 核验的屏幕外截图结论。普通标题窗口会被系统约束回屏幕边缘；强制完全屏幕外并验证与所有屏幕不相交后，输入仍可执行，但 `screencapture` 失败，ScreenCaptureKit 对存活窗口也返回 -3811。不能把输入通过写成完整零干扰视觉闭环通过。详见 [第二轮记录 BG-D05～BG-D08](../../reviews/plugin-preview/plugin-preview-renderer-input-2026-11-10.md)。正式契约不变，PV-T02 原生输入隔离与 PV-T03 仍未放行。

## PV-D09：分层原生捕获取得屏幕外小样本闭环（2026-11-10）

完全屏幕外、实际与所有屏幕不相交的共享视图中，`NSView.cacheDisplay` 能捕获 2D，但漏掉 SceneKit；同一真实 `SCNView.snapshot()` 能捕获完整 iPod。按实际视口区域叠加两者后，主控查看完整合成图，确认 3D 与底部 2D 控件可见。指定窗口事件触发真实 `toggle`，初次及追加三次独立运行均取得更新后的场景快照；追加三轮最终 UI 树均为 `play.fill=2、pause.fill=0`，无应用激活通知，前台和指针端点相同。

这补充了另一条捕获路线，不取代 PV-D08 的 WindowServer／ScreenCaptureKit 失败结论。玻璃缓存虽可见，桌面背景采样、复杂遮挡／裁剪、分层同帧性及完整生命周期无干扰仍未验；本例合成不是通用截图实现。详见 [第三轮 BG-D09～BG-D11](../../reviews/plugin-preview/plugin-preview-view-capture-2026-11-10.md)。正式后台 nativeClick 契约不变，PV-T02／PV-T03 均未放行。

## PV-D10：几何层级有改进，玻璃保真与动画严格同帧未通过（2026-11-10）

原生窗口参考与完全屏幕外捕获对照中，简单末层叠加会破坏父级圆角裁剪、不透明遮挡，并吞掉产品真实的 SwiftUI 爱心前景。实验性原层级快照替换改善本例几何关系：最终轮差异像素占比由圆角 18.30669%／遮挡 10.34658% 降至 0.03924%／0.01066%，但并非逐像素一致。原生玻璃仍明显失真，纯 2D 玻璃对照同样失败；半透明结果跨轮变化，不能宣布普遍保真。

真实相机动画三轮各 20 样本：两层间等待 20ms 共 60/60 状态错位；同一主线程段、相机完成后均未记录相机模型角度差。但 SwiftUI／SceneKit GPU 呈现严格同帧尚无证据，不能用“无 await”替代该验收。前两轮有前台／指针变化，来源未确定；最终轮无激活事件且前台／指针端点相同，不覆盖全部轮次。详见 [第四轮 BG-D12～BG-D16](../../reviews/plugin-preview/plugin-preview-layer-fidelity-2026-11-10.md)。遵照用户要求，不接入正式工具，不改变 nativeClick 契约，PV-T02／PV-T03 仍未放行。

## PV-D11：默认颜色空间漂移可复现，受控时间回放有效，正式隔离仍未放行（2026-11-10）

独立原生校准在固定显示器 ID 和窗口配置后发现：外接屏窗口完全移出屏幕后，默认颜色空间由 U2790B 变为 Color LCD；显式 sRGB 后保持不变，本例半透明缓存的内外差异消失。原生玻璃在屏幕内缓存中就已失真，固定 sRGB 也不能修复。受控 SceneKit 动画在显式时间、事务提交和更新的组合下，取得四个不同相位及四对同时间回放规范化像素差 0，但尚未在真实产品的 SwiftUI／SceneKit 多时钟中复验。

最终校准轮记录候选实际激活事件 1、前台变化，来源未确定，不能写为零干扰。详见 [第五轮 BG-D17～BG-D20](../../reviews/plugin-preview/plugin-preview-color-clock-2026-11-10.md)。本轮只做校准，未接入正式工具；原生玻璃、产品同帧及激活来源仍待解决，后台 nativeClick 契约不变，PV-T02／PV-T03 不放行。

## PV-D12：真实 Renderer 颜色漂移复现，显式时间不足以固定产品相机（2026-11-10）

本条补充 PV-D11 的产品复验证据，保留其历史激活事实。真实共享 Renderer 的 2D 一轮、iPod 3D 两轮共 18 个静态组中，18 对原生参考像素差为 0；外接屏默认窗口／缓存再次发生 U2790B → Color LCD 漂移，全部 12 个显式 sRGB 组内外缓存像素差为 0。但与原生参考仍不同，且内建屏 sRGB 下 2D／3D 半透明组差异像素约 25.13%／24.29%，不能将固定 sRGB 推广为保真修复；显式缓存位图颜色空间也未消除残差。

真实 iPod 相机两轮各 8 次重复显式 renderer 时间 0.125s，yaw 仍从约 0.43°→54.18°、0.41°→63.85°，图像差异分别约 60.32%／65.21%。SceneKit 捕获时间不能自动控制既有主 RunLoop Timer；捕获后原场景身份、播放参数保持，相机继续推进并收敛，但严格多层同帧及完整副作用恢复仍未过。

8 个有效候选进程的启动前独立观察与内部阶段日志未复现激活，前台 PID 保持；后两批另有 457 个约 50ms 心跳。2D 矩阵和第二轮相机记录指针变化、来源未采集，仍不能宣称整体零干扰；第五轮的激活来源没有解决。详见 [第六轮 BG-D21～BG-D25](../../reviews/plugin-preview/plugin-preview-renderer-color-lifecycle-2026-11-10.md)。本轮未接入正式工具，原生玻璃失败结论保留，后台 nativeClick 契约不变，PV-T02／PV-T03 不放行。

本条后续工程路线的优先级被 PV-D13 更新；分层缓存失败、时间反例和历史监测事实继续保留。

## PV-D13：不排序的原生窗口取得本机后台视觉闭环，可行但尚未正式接入（2026-11-10）

本条“尚未正式接入／后台 nativeClick 为 unsupported”的状态被 PV-D14 取代；实验失败、保真与兼容性边界保留。

与完全离屏和分层缓存不同，最终实验窗口从创建到后台验证结束均不排序到屏幕，保持 alpha=1，使用不可成为 key／main、鼠标穿透的 nonactivating NSPanel 和共享 Renderer，直接按 windowNumber 取得原生图。2D 三个进程经原 AX press 完成 Go／禁用 Stop／Mute／缺失标签对照；3D 四个进程共 16 次 toggle、4 次 love、4 次原生视图拖动，取得状态和画面更新。七个进程共有 83 张有效、非透明、非单色后台截图；803 个后台外部样本的候选上屏窗口数均为 0，目标未激活、未成为 key。前台 PID 各轮保持；几何轮存在来源未采集的指针变化，不扩大为全系统零干扰保证。

普通 2D 隐藏图与原生参考 RGB 差为 0；3D 和新增圆角 mask／半透明遮挡组的残差全部在原生玻璃区域，最大通道差 7、全图 MAE 约 0.458，区域外像素一致。真实爱心、模型动画、玻璃及遮挡来自同一原生返回图，避免工具自行跨调用拼接；完整逐像素玻璃等价和跨时间源确定性回放仍未通过／未证明。透明 orderBack→orderOut 初始化因提交时序导致空图，且曾记录上屏样本，已否决；不能以早期成功样本交付。

裁决是**本机“不占用用户前台的插件操作与看图”目标可实现**，后续优先采用不排序的原生表面和目标进程内输入适配。正式工具尚未接入；macOS 12、Intel、跨 Space、完整输入及压力矩阵未完成，PV-T02／PV-T03 发布门禁不放行，后台 nativeClick 仍为 unsupported。详见 [第七轮 BG-D26～BG-D33](../../reviews/plugin-preview/plugin-preview-hidden-window-feasibility-2026-11-10.md)。

## PV-D14：隐藏原生表面正式接入，限定范围本机回归通过（2026-11-10）

用户授权正式接入后，`run --background` 采用 `PluginPreviewCaptureSurface`：accessory 进程、nonactivating NSPanel、alpha=1、屏幕内几何，从创建到结束不排序到屏幕；输入和原生窗口截图复用同一 `@ObservedObject` 共享 Renderer。每次运行在步骤前及最终捕获验证图像，准备／输入／捕获检查隔离，失败不回退前台。标签 `nativeClick` 通过只读父进程 AX 准备和既有 press；新增 `nativeClickAt`／`nativeDrag` 经 hitTest 命中真实 SceneKit 视图并调用鼠标方法，不直调业务动作、不投递全局键鼠。

正式二进制的后台脚本最终共 17 轮、1318 个独立观察样本：上屏、目标前台及激活事件均为 0。原有 7 步场景、七类输入负向／worker 抛错、超大表面环境错误、点击后内容增长、SIGTERM 清理、四个 iPod 场景均符合预期；成功图独立解码非透明／非单色，动作前后像素有差异，toggle 后 worker 树更新。另九轮浅深 2D、iPod 点击／爱心／拖动及玻璃截图的 788 个样本上屏／激活／前台变化均为 0，并补看内容增长图。修复 AppKit 终止时失败退出码变 0，以及信号清理和在途步骤争写退出码的问题。

`make plugin-preview-build`、`make build`、`make test-unit`（804 项含 9 跳过、0 失败）、场景、worker、产物、CLI 67 项、后台与基线回归、契约守卫通过。Schema 增量扩展仍为 v1，但契约哈希变化；当前工作区共享源码已变化，同步 rendererRevision，旧基线须重新接受。未修改宿主渲染业务，未运行本体或真实 Music；未提交／推送／发布。macOS 12、原生 Intel、跨 Space、压力、键盘／hover／滑块、玻璃逐像素等价与多时钟确定性仍未放行；PV-T03 未完成。完整证据见 [正式接入记录](../../reviews/plugin-preview/plugin-preview-background-integration-2026-11-10.md)。
