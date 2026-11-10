# 真实 Renderer 颜色复验、生命周期监测与显式时间反例

日期：2026-11-10。接续[第五轮校准](plugin-preview-color-clock-2026-11-10.md)。本轮继续小范围对照，不接入正式工具，不改变后台 `nativeClick` 的 `unsupported` 契约。

实测环境：arm64、macOS 27.2（26B123）、Xcode 27.2（27B52）、本机 GUI 会话及两台显示器；不外推到 macOS 12 或其他系统版本。

## BG-D21：实验范围与有效样本

与第五轮的独立校准不同，本轮直接编译当前 `project.yml` 中预览 target 的 97 个非入口 Swift 文件，加临时入口和实验助手；使用真实共享 `PluginSlotSurface`、`PluginOverlayView`、`PluginScene3DPointerView`。复用已有预览 App 资源、worker，以及带模块头的既有 GLTFKit2 构建产物。所有入口替换、观察进程、对比程序、候选 App 和产物都在系统临时目录，仓库 Swift、构建配置和正式工具未修改。

使用两类内容：

- 2D：仓库 `Tests/PluginPreview/Fixtures/native-input/plugin`，移除场景步骤，只渲染原控件，壳尺寸 360×115pt。
- 3D：外仓 `com.switchly.music-controls`、原 GLB、合成 `media-playing.json`，`ipod3d=true`、宽 300pt、英文、关闭玻璃，壳尺寸 300×516pt。真实媒体不参与。

两者都经过原 worker 会话装载和输出解码。本轮颜色样本的动作回调不执行业务动作；相机实验直接调用既有 `controller.spin(.right)` 作为动画刺激，**不把它计为原生输入验证**。本轮不重新运行 `nativeClick` 回归。

有效运行共 8 个独立候选进程：仅会话启动 1 次、仅建窗后置 2 次（2D／3D）、完整颜色矩阵 3 次（2D 一轮、3D 两轮）、真实相机显式时间 2 次。颜色共 18 组，16 张相机样本图。只有到达实验结束标记、生成所需 JSON 和图像的运行计入有效样本，不按进程退出码独立判定。

探针开发失败也保留事实：最初命令使用了错误的参数形式，被入口拒绝；直接构造 `NSApplication` 子类导致 AppKit 断言 `More than one NSApplication instance was created`，改用子类的 `shared` 单例后恢复；音乐夹具的绝对路径被安全校验拒绝，改为临时场景目录内的相对路径和复制的合成夹具后才采用结果。这些属于探针错误，不作为产品保真或隔离失败的证据。部分失败进程退出码同样为 0，再次说明必须检查内容。

## BG-D22：固定 sRGB 消除本例内外缓存漂移，但未保证原生保真

固定启动时的两台显示器对象：ID 1 为 Color LCD，ID 3 为 U2790B。每次原生参考前核对窗口实际显示器 ID，不跟随 `NSScreen.main`。窗口 accessory、borderless、桌面层级以下，只 `orderBack`；只按窗口 ID 捕获候选自身，不捕获用户桌面或其他应用。

每台显示器分别比较三配置：

1. `default`：窗口和缓存采用默认颜色空间。
2. `window-sRGB`：只显式设置 `window.colorSpace = .sRGB`。
3. `window-bitmap-sRGB`：再由 sRGB CGContext 创建带明确颜色空间的缓存位图，交给 `cacheDisplay`。

在真实内容上增加 alpha=0.55 的青色原生前景，颜色为 sRGB `(0.12, 0.65, 0.82)`，frame 为 `(20, height×0.2, width−40, height×0.28)`。此矩形是实验遮挡层，不冒充插件已有布局。3D 沿用原层级替换：同一个 SCNView 取快照，在原父视图和 frame 放 NSImageView，临时隐藏原视图，缓存后移除替身并恢复原隐藏状态。2D 直接缓存原树。

顺序为：连续两张原生参考 → 屏幕内缓存 → 移至 `(-10000,-10000)`、断言与所有显示器 frame 不相交 → 屏幕外缓存。所有屏幕外样本 `window.screen=nil`。18 对原生参考的规范化 RGB 最大通道差均为 0。

图像统一转换为 8-bit sRGB RGB；2D 比较尺寸 720×230px，3D 为 600×1032px。抽查内建屏及外接屏 3D 原始参考、内外缓存也都是 600×1032px，本例并非由 1×／2×缩放差异产生。差异像素仍指某一 RGB 通道绝对差 >8，MAE 范围 0～255，只作误差描述，不新增验收阈值。

下表为 2D 矩阵和第二轮 3D 矩阵的真实输出；默认 3D 内外 MAE 的极小非零值也保留：

| 内容 | 显示器／配置 | 屏幕外缓存对原生参考：差异像素 | MAE | 屏幕内外缓存 MAE |
| --- | --- | ---: | ---: | ---: |
| 2D | d1-default | 0.39553% | 0.138029 | 0.00000000 |
| 2D | d1-window-sRGB | 25.12983% | 1.300870 | 0.00000000 |
| 2D | d1-window-bitmap-sRGB | 25.12983% | 1.300870 | 0.00000000 |
| 2D | d3-default | 0.55676% | 0.677329 | 0.62253824 |
| 2D | d3-window-sRGB | 0.58213% | 0.852878 | 0.00000000 |
| 2D | d3-window-bitmap-sRGB | 0.58213% | 0.852878 | 0.00000000 |
| 3D | d1-default | 0.17765% | 0.169643 | 0.00000054 |
| 3D | d1-window-sRGB | 24.29490% | 1.077574 | 0.00000000 |
| 3D | d1-window-bitmap-sRGB | 24.29490% | 1.079273 | 0.00000000 |
| 3D | d3-default | 13.93298% | 0.864245 | 0.79275894 |
| 3D | d3-window-sRGB | 0.22028% | 0.503043 | 0.00000000 |
| 3D | d3-window-bitmap-sRGB | 0.22028% | 0.501839 | 0.00000000 |

第一轮 3D 复验：外接屏默认内外 MAE 同为 0.79275894，显式 sRGB 内外均为 0；内建屏显式 sRGB 对原生参考的差异像素同为 24.29490%。两轮 3D 的小范围残差并非全部逐像素相同，未把它们当成确定性基线。

直接记录到外接屏默认窗口／缓存的颜色空间为 `U2790B → Color LCD`；只固定窗口 sRGB 后，默认缓存也已报告 sRGB，再显式创建 sRGB 位图没有消除剩余原生参考差异。全部 12 个显式 sRGB 组的内外缓存规范化 RGB 差为 0。

**能确认的范围**：第五轮的颜色漂移路径在真实共享 Renderer 上复现；固定窗口颜色空间能消除本例这类内外缓存漂移。

**不能升级的结论**：缓存稳定不等于与 WindowServer 原生画面一致。内建屏固定 sRGB 后，2D／3D 的半透明区域出现约 25.13%／24.29% 差异像素，均比默认配置大；外接屏 3D 的整体误差改善，但仍有残差。主控实际查看 2D 内建屏 sRGB，以及 3D 外接屏默认／sRGB、内建屏 sRGB 的四列对比图（原生参考／屏幕内缓存／屏幕外缓存／放大 4 倍差异），确认 iPod、控件和前景层存在，差异主要落在半透明区域及少量文字、边缘、进度条。未锁定底层混色或显示转换的唯一原因，不能把“一律设置 sRGB”直接推广为正式修复。

本轮没有复测圆角矩阵和原生玻璃；[第四轮](plugin-preview-layer-fidelity-2026-11-10.md)的几何边界与[第五轮](plugin-preview-color-clock-2026-11-10.md)的玻璃失败结论继续有效。

## BG-D23：显式 SceneKit 时间不能固定真实相机 Timer

在真实 iPod 的同一场景和相机上创建临时 SCNRenderer，保持 `isPlaying=false`、关闭 jitter。使用既有 controller 开始旋转，每次异步等待 35ms，再重复相同捕获组合：

```swift
renderer.sceneTime = 0.125
SCNTransaction.flush()
renderer.update(atTime: 0.125)
let image = renderer.snapshot(
    atTime: 0.125,
    with: CGSize(width: 600, height: 960),
    antialiasingMode: .multisampling4X
)
```

这不是重建校准方块动画：保持真实产品场景的现有时间归属，没有把产品 Timer 强行改为 sceneTime 动画。每轮 8 张图，16 次记录的显式时间全部是 0.125，但相机状态和图像仍推进：

| 轮次 | 首张 yaw | 末张 yaw | 首末图差异像素 | MAE |
| --- | ---: | ---: | ---: | ---: |
| 1 | 0.425925° | 54.178984° | 347470/576000（60.32465%） | 65.914584 |
| 2 | 0.414704° | 63.849486° | 375624/576000（65.21250%） | 81.961970 |

每个同步捕获段内的 yaw 前后相同；段与段之间主 RunLoop Timer 继续更新相机。第二轮实际看过首末并排图，iPod 从近正面变为明显侧面，排除“只改数字、图像不动”的情况。异步等待是 35ms，实际样本间隔含渲染耗时，未当成精确 35ms 帧间隔。

该反例证明：BG-D19 的受控 SceneKit 动画回放不能自动迁移为产品相机回放；单独设置 renderer 时间不会回滚当前模型相机，也不会冻结 SwiftUI／DispatchQueue 等其他时间源。真实相机由[共享 controller](../../../Sources/Services/Plugins/PluginScene3DController.swift)的帧调度推进，严格多层同帧继续未通过。

捕获结束后清空临时 renderer 的 scene／pointOfView 引用。两轮均记录：原 SCNView 的 scene、pointOfView、controller 实例场景身份保持；`isPlaying`、`rendersContinuously`、`sceneTime` 与捕获前相同；controller 仍 active。350ms 后 yaw 分别继续到 −154.86449°、−139.58415°，随后两轮都正常 settled。角度跨越 ±180°，不将直接相减当成实际转角。

这仅覆盖上述身份、参数和相机继续推进／收敛，不证明爱心、按压 SCNAction、跑马灯、输入、取消或所有 GPU 状态无副作用。本轮没有暂停生产 Timer，也没有验证统一时间的捕获事务。

补充只读核查：现有 controller 的 `stop()`／`start()` 是生命周期接口，不能直接当成保存相位的暂停／恢复。`Scene3DInputSession.start/stop` 会调用 `camera.stopInertia()`，清空速度和 spin；controller 停止时丢弃帧调度器及其时间戳，重新 start 不恢复原 `spin.elapsed`。爱心还使用 SwiftUI 动画和 DispatchQueue 延迟，按压使用 SCNAction。以上为源码路径结论，未在本轮调用这些接口做相位恢复实验；后续不能为捕获简单包一层 stop/start，就宣称恢复了原动画。

## BG-D24：扩展到启动前的观察未复现激活，历史来源仍未解决

独立观察进程在候选创建之前开始监听 NSWorkspace 应用激活／启动／退出通知，父进程同时记录每个候选 PID、启动和退出时刻；观察进程在候选退出后继续保留至少 300ms。候选内部记录入口、单例创建、didFinishLaunching、worker 就绪、hosting／window 创建、orderBack、screencapture、SceneKit snapshot、移出屏幕和清理阶段，并观察应用激活、成为 key 和退出通知。只记 PID、阶段、状态和指针位置，不记其他应用名称、不读取键盘内容、不采集其他窗口。

直接执行候选二进制时，本轮 NSWorkspace 没有发出候选 launch／terminate 通知，因此不把它们声称为已收到；生命周期边界以父进程创建／回收记录及候选日志交叉确定。首批有效运行仅有通知监听和阶段采样；后两批额外增加 50ms 前台 PID 心跳，分别取得 344／113 个样本，最大实测间隔 53.722／51.933ms。通知未收到与采样值不变是不同证据，均保留边界。

8 个有效候选运行合计 475 个内部阶段样本，实际输出：

```text
valid_runs=8
candidate_didBecomeActive=0
candidate_key_samples=0
candidate_legacy_activate_calls=0
candidate_own_mouse_down_up=0
front_pid_unique_per_run=1
workspace_activation_events=0
```

第二／第三批 457 个外部心跳的前台 PID 也始终相同。捕获模式本身没有触发本轮可观察的候选激活；未复现第五轮异常，**来源仍未确定，BG-D20 的实际激活事实保留**。没有以本轮零事件样本取代历史失败，也没有推断用户或系统触发。

指针方面，2D 矩阵阶段记录到 7 个不同位置，第二轮相机实验有 3 个不同位置；来源没有采集。其他有效进程各只有 1 个位置。虽然没有候选自己的鼠标按下／抬起事件，本轮仍不宣称全部零指针干扰或完整零干扰。未测试用户连续前台输入、键盘隔离、跨 Space、候选点击激活、系统权限变化及不同系统版本。

## BG-D25：验证、边界与下一步

实际执行：临时候选三次 Swift 编译均退出 0，独立观察器和像素比较程序编译退出 0；有效运行逐项检查结束标记、JSON、图像和身份，不只检查退出码。共享源码守卫输出：

```text
共享源码守卫通过：33 个核心类型各一处定义，预览 target 编译宿主源码
```

主控已看上述真实颜色和相机图像；18 对静态参考的规范化 RGB 最大通道差 0、12 组显式 sRGB 内外缓存差 0、两轮相机各 8 样本的证据一致性检查通过。文档本地链接和 `git diff --check` 通过。仓库没有 Swift 实现修改，因此未运行宿主 `make build`／`make test-unit`；本轮临时候选的真实编译与运行不替代宿主全量回归。

问题 → 方案 → 后续：

- 颜色漂移已从校准复现到共享 Renderer，但原生混色保真未过 → 保留窗口颜色控制作为实验变量，不能默认采用 sRGB → 下一步区分目标显示器输出、原生合成和缓存混色，维持原生参考标准。
- 显式 SceneKit 时间无法固定真实 Timer 相机 → 捕获需要同时控制模型状态与各呈现时间源 → 后续验证捕获事务的状态快照、取消与恢复；爱心和按压动画仍需独立覆盖。
- 本轮未复现候选激活 → 保留启动前独立监测和阶段归属 → 异常再次出现时按 PID／时间定位，不用重跑挑选零事件样本结案。
- 原生玻璃缓存失败继续存在 → 需要同一可捕获原生合成表面的隔离呈现方案 → 不用自制 blur 冒充原生材质，不以本轮普通内容结果放行。

本轮仅新增本报告、台账和索引，保留用户已有工作区修改；临时候选、脚本、PNG、JSON 和日志核验后清理。未启动真实媒体、重启正式 Switchly、提交或推送。PV-T02／PV-T03 继续不放行。
