# 完全屏幕外的共享原生视图捕获对照

日期：2026-11-10。接续 [第二轮输入与捕获实验](plugin-preview-renderer-input-2026-11-10.md)。本轮仅验证新捕获假设，不修改正式工具、共享 Swift 源码或公开契约。

## BG-D09：整棵视图缓存不能覆盖 SceneKit，独立场景快照可用

按当前 `project.yml` 编译预览 target 的 98 个 Swift 源文件，仅在系统临时目录替换入口。候选复用既有预览 App 资源与 worker，并使用含模块头文件的现有 GLTFKit2 framework。直接编译命令的核心为 `xcrun swiftc -parse-as-library -swift-version 5 -module-name SwitchlyPluginPreview … -framework GLTFKit2`，实际 `sources=98`、`compile_exit=0`。初次误用发行包中不含模块头的 framework 导致 `no such module GLTFKit2`，改用现有 Debug framework 后通过；不是共享代码缺陷。

候选使用观察 `PluginPreviewState` 的 `NSHostingView`，内部仍为共享 `PluginSlotSurface`，动作经原 `state.perform → session → worker JS → render`。窗口为 accessory、borderless，只调用 `orderBack`；实验窗口覆盖 `constrainFrameRect`，不约束回可见区域。对照实际 frame 与所有 `NSScreen.frame`，不是只检查请求坐标。

| 捕获对象 | 实际窗口 frame（pt） | 原生视图缓存 | SceneKit 快照 |
| --- | --- | --- | --- |
| 仓库 native-input 2D 夹具 | `(-10000,-10000,360,115)` | `720×230`，文字、按钮、开关可见 | 无 SCNView |
| 真实 iPod 3D 插件及底部 2D 控件 | `(-10000,-10000,300,516)` | `600×1032`，只见背景和底部控件，3D 区域空白 | `600×960`，完整 iPod、合成封面、文字、进度和轮盘可见 |
| 真实 glass surface 包装的 2D 夹具 | `(-10000,-10000,360,123)` | `720×246`，浅蓝表面、文字及控件可见 | 无 SCNView |

以上均实际输出 `overlap=false active=false key=false`。主控已分别读取三类缓存图及 3D 前后快照；缓存漏掉 SceneKit 的失败结果保留，不能仅以 PNG 存在判定通过。

使用公开 API：`bitmapImageRepForCachingDisplay(in:)` 配合 `cacheDisplay(in:to:)`；真实 `PluginScene3DPointerView` 上调用继承的 `SCNView.snapshot()`。Apple 对前者的说明是绘制视图及其后代，对后者的说明是将场景渲染为图片；本轮实测说明不能假定前者自动包含 SceneKit GPU 表面。[NSView 文档](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:))、[SCNView 文档](https://developer.apple.com/documentation/scenekit/scnview/snapshot())。当前 SDK 已标记 SceneKit API 弃用；本轮沿用仓库既有 SceneKit，无新增依赖。

## BG-D10：真实 3D 点击与分层捕获形成有限闭环

只读复制外仓真实音乐插件与 GLB，使用合成 `media-playing.json`，开启 `ipod3d`，宽度 300pt、英文、深色、关闭玻璃。不启动真实 Music 或媒体采集。

对同一屏幕外原生视图先捕获，再在 300×480pt 的真实 SceneKit 视口中，以已知 top-left 坐标 `(128,360)` 换算窗口坐标，向指定窗口依次分派 `NSEvent.mouseDown/mouseUp`，等待原会话更新，再捕获。没有直接调用控制器指针方法或业务 action。本轮采用上一轮已知坐标，不是从图片自动定位任意控件的证明。

首次及追加三次独立运行均输出：

```text
PROBE frame=(-10000.0, -10000.0, 300.0, 516.0) overlap=false active=false key=false
PROBE routed_action=toggle
PROBE front_changes=0 front_same=true pointer_same=true
```

追加三轮均为 `exit=0 toggle=1 play=2 pause=0 image_changed=True`。`play/pause` 数量来自动作后的真实 `ui-tree.json`，图片变化以捕获文件 SHA-256 不同确认；主控实际看图确认暂停符号变为播放符号，不仅依赖哈希。未执行原 7 步场景，本轮不将这些样本写成完整场景回归通过。

实验合成使用原生 NSImage 绘制：以整棵视图缓存为底，真实 SCNView 快照按 `view.convert(view.bounds,to:host)` 的实际区域覆盖。本例区域为 `(0,0,300,480)`，主视图 300×516pt；输出保持 2 倍缩放的 `600×1032`。主控实际查看前后合成图：iPod、真实屏幕纹理、底部两个 2D 控件均可见，动作变化正确。初版合成误将像素数当 pt 导致再次放大，纠正尺寸后才使用最终产物；未将错误尺寸视为通过。

本例 SCNView 位于顶层独占区域，区域换算与绘制针对该布局。没有实现通用裁剪、圆角、遮挡顺序或多 SCNView 合成器；场景图和 2D 缓存顺序采集，也未证明动画情况下的同帧一致性。不能将该探针直接包装为任意原生窗口截图能力。

## BG-D11：无干扰证据、玻璃边界与放行结论

每次候选订阅 `NSWorkspace.didActivateApplicationNotification`，记录捕获前后的前台 PID 及指针位置。初次 2D／3D、玻璃和追加三次 3D 均无激活通知，前台与指针端点相同。本轮没有上一轮的 10ms 指针采样或 CGEventTap 来源监测，不能排除期间移动后恢复，也没有验证用户应用内部焦点竞争。监测从捕获函数进入时开始，不是覆盖完整进程生命周期的审计。

玻璃样本复用仓库 `run-baseline-tests.sh` 的真实 `surface(material:glass)` 包装方法，图中表面可见。这只证明缓存不是全空，未做同一场景的 WindowServer 像素对照，未证明桌面背景采样、原生透明材质或所有主题与玻璃开关一致。

**结论**：普通 2D 与当前真实 iPod 场景，已有“完全屏幕外原生输入 → JS 状态更新 → 共享视图与真实 SceneKit 快照 → 完整合成图”的小样本证据。BG-D08 的 WindowServer／ScreenCaptureKit 屏幕外捕获失败仍成立；本轮通过的是另一条捕获路径。可优先验证分层捕获的保真度、裁剪与同帧一致性，暂不必将独立 GUI runner 当成唯一候选。正式 `run --background` 仍拒绝 `nativeClick`，PV-T02／PV-T03 均不放行。

## 门禁与清理

- `./Tools/PluginPreview/shared-source-check.sh`：`共享源码守卫通过：33 个核心类型各一处定义，预览 target 编译宿主源码`。
- `git diff --check` 与本轮文档本地链接检查通过。仓库仅新增实验记录和台账／索引增补；未运行宿主全量构建或单测，因为没有修改仓库 Swift。临时候选的 98 源文件直接编译已真实通过。
- 主控已实际查看 2D、缺失 3D 的缓存、真实 3D 前后快照、完整合成前后图与玻璃缓存。
- 未安装、重启正式 Switchly、操作真实媒体、提交或推送。保留用户已有工作区修改与文档迁移。
- 候选、辅助脚本、PNG、运行日志均在系统临时目录，完成核验和记录后清理；未交付可复跑正式工具，文档保存方法与关键输出。

问题 → 方案 → 后续：整棵原生视图缓存缺失 SceneKit → 本例按实际视口区域叠加真实场景快照获得完整图 → 下一步补充遮挡／裁剪、主题与材质对照、动画同帧性和截图坐标回放，再决定正式协议及实现。
