# 固定显示配置与显式 SceneKit 时间校准

日期：2026-11-10。接续 [第四轮保真度实验](plugin-preview-layer-fidelity-2026-11-10.md)。本轮只排查颜色路径与呈现时间，不接入正式工具。

## BG-D17：默认窗口颜色空间在屏幕外发生变化

本轮刻意缩小为独立原生 AppKit／SceneKit **校准探针**，不运行产品 Renderer、音乐插件或 worker，也不把校准图冒充真实产品截图。目的是隔离上一轮发现的两个变量，排除 JS、媒体状态和 3D 合成顺序的影响。Swift 探针及运行产物仅位于系统临时目录。

固定使用启动时取得的两个 NSScreen 对象及显示器 ID；每次参考截图前核验窗口实际显示器 ID，没有继续跟随可变的 NSScreen.main。实际显示器：

- ID 1：`Color LCD`，frame `{{0,0},{1352,878}}`。
- ID 3：`U2790B`，frame `{{1352,-104},{1920,1080}}`。

每个显示器分别采用默认窗口颜色空间和显式 `window.colorSpace = .sRGB`，测试普通 alpha=0.55 前景和原生玻璃，共 8 组。根视图 240×240pt，20pt 格子的双色棋盘；前景位于 `(30,50,180,140)`。玻璃使用 `.hudWindow/.withinWindow/.active`，不采集用户桌面背景。

窗口为 accessory、borderless、桌面层级以下，只 orderBack。参考图来自候选自身窗口的 `screencapture -x -o -l`，连续捕获两次；再分别取屏幕内缓存和移至 `(-10000,-10000)` 后的缓存。8 对原生参考图的规范化 RGB 差异均为 0；所有屏幕外组与所有屏幕 frame 不相交。比较统一转换为 480×480、8-bit sRGB RGB，“差异像素”沿用通道绝对差 >8 的描述口径，MAE 范围 0～255；该阈值不是正式验收标准。

最终轮实际输出：

| 显示器 ID | 窗口配置 | 样本 | 窗口颜色空间：屏幕内 → 屏幕外 | 屏幕外缓存对原生参考的差异像素 | MAE | 内外缓存 MAE |
| --- | --- | --- | --- | ---: | ---: | ---: |
| 1 | default | alpha | Color LCD → Color LCD | 0.000% | 0.38936 | 0.00000 |
| 1 | default | glass | Color LCD → Color LCD | 43.750% | 9.77941 | 0.00000 |
| 1 | sRGB | alpha | sRGB IEC61966-2.1 → sRGB IEC61966-2.1 | 0.000% | 0.16667 | 0.00000 |
| 1 | sRGB | glass | sRGB IEC61966-2.1 → sRGB IEC61966-2.1 | 43.750% | 9.57382 | 0.00000 |
| 3 | default | alpha | U2790B → Color LCD | 21.875% | 2.35417 | 2.35417 |
| 3 | default | glass | U2790B → Color LCD | 43.750% | 9.64593 | 0.38542 |
| 3 | sRGB | alpha | sRGB IEC61966-2.1 → sRGB IEC61966-2.1 | 0.000% | 0.00000 | 0.00000 |
| 3 | sRGB | glass | sRGB IEC61966-2.1 → sRGB IEC61966-2.1 | 43.750% | 9.47849 | 0.00000 |

关键证据是外接屏默认窗口的 `U2790B → Color LCD`。完全屏幕外时 `window.screen=nil`，记录中的 offWindowDisplayID=0 仅是实验输出的 nil 哨兵，不代表真实显示器 ID。显式 sRGB 的窗口颜色空间则保持不变。

这证明**至少存在一条可复现的默认颜色空间漂移路径**。同一外接屏半透明样本在默认配置下，内外缓存 MAE 为 2.35417；显式 sRGB 后为 0，与规范化后的原生参考也为 0。内建屏显式 sRGB 样本的通道差均未超过 8，但 MAE=0.16667，并非逐像素完全一致。

该结果为上一轮半透明跨轮差异提供了具体排查方向，不能反推其全部差异都由这一因素造成。尚未在真实共享 Renderer、SCNView 快照、原层级替换及多显示器切换组合中复验，不能直接宣布正式预览颜色保真已解决。另未修改系统显示配置或读取颜色配置文件，只读取系统公开颜色空间元数据。

最早的双屏探针曾因误用 NSWindow 初始化的屏幕局部坐标而触发 display-drift 断言；显式设置全局 frame 后重跑，并保留窗口显示器 ID 核验，才采用完整矩阵结果。探针错误不作为产品问题。

## BG-D18：固定 sRGB 没有修复原生玻璃缓存

8 组中，所有玻璃缓存对原生参考的差异像素比例均为 **43.75%**，恰好覆盖本例玻璃矩形所占面积，MAE 约 9.48～9.78。显式 sRGB 后两个显示器的屏幕内／外缓存均相同，却仍与原生参考不同。

主控实际查看内建屏显式 sRGB 的玻璃参考和缓存：参考图将棋盘模糊为连续材质，缓存仍清楚保留棋盘格。另实际查看外接屏默认／sRGB 半透明图，未仅靠文件存在或数值下结论。

可以缩小结论：**本例玻璃差异在窗口仍位于屏幕内时就已存在；不是仅由完全屏幕外或默认颜色空间漂移产生。** 两种因素需分别处理。仍未定位 AppKit 内部背景滤镜或合成器的具体实现，未用自制模糊替代原生材质，也未将截图标准降为“能看到控件”。

## BG-D19：显式呈现时间在受控 SceneKit 场景中可重复

独立 SceneKit 校准为正交相机、黑背景、红色方块。通过 CABasicAnimation 的 position.x 从 -0.9 到 +0.9 运动，关闭灯光依赖、抖动，使用 4× MSAA。不加载 iPod，不涉及真实 SwiftUI 或产品相机 Timer。

先后实验必须区分：

1. 只指定 snapshot(atTime:)：四个时间点的 presentationX 均约 -0.9，图片也不变，**未证明动画推进**，不能把重复图相同计为通过。
2. 启用播放并设 sceneTime 的中间版本：仍未取得正确四相位，且一次回放不同；该版本未通过。
3. 最终组合：动画使用 usesSceneTimeBase=true、非零 beginTime=0.000001、fillMode=both、保留动画；renderer.isPlaying=false。先 flush 场景事务，每个样本设置 sceneTime、flush，再 renderer.update(atTime:)，最后 snapshot(atTime:with:antialiasingMode:)。这组取得真实动画推进及相同时间回放的规范化 RGB 一致。

| 显式时间 s | 实际 presentationX | 模型 position.x | 同时间回放 MAE |
| ---: | ---: | ---: | ---: |
| 0.125 | -0.6750018 | 0 | 0 |
| 0.375 | -0.2250018 | 0 | 0 |
| 0.625 | 0.2249982 | 0 | 0 |
| 0.875 | 0.6749982 | 0 | 0 |

采样顺序为上述四时刻再回放相同四时刻，中间各有 35ms 实际异步等待。两个端点图像之间的差异像素为 9542/230400（规范化后约 4.14149%），MAE=4.66425；主控实际查看方块位于左右不同位置，确认不是“动画始终没动”的伪通过。四对同时间回放规范化像素差为 0。

这只验证**最终设置组合**，没有做各个开关逐项消融，不能声称某一个 flush 或 beginTime 单独解决全部问题。原始 SceneKit 输出请求为 256×256px，比较统一规范化到 480×480px，未以 PNG 字节哈希代替像素比较。

Apple 文档将 snapshot(atTime:) 定义为按给定系统时间绘制，sceneTime 则只影响采用场景时间基准的动画。这两种时间以及产品的主线程 Timer、SwiftUI 动画不能直接混同。参考：[snapshot(atTime:)](https://developer.apple.com/documentation/scenekit/scnrenderer/snapshot(attime:with:antialiasingmode:))、[sceneTime](https://developer.apple.com/documentation/scenekit/scnscenerenderer/scenetime)、[usesSceneTimeBase](https://developer.apple.com/documentation/quartzcore/caanimation/usesscenetimebase)。

本轮**没有**证明真实共享 Renderer 的 2D／3D 同帧：产品爱心、跑马灯、DispatchQueue 回调、相机 Timer 和按压 SCNAction 尚未统一；修改现有场景时钟／播放状态还需要验证恢复和副作用。不得把本例规范化相同当成正式工具动画验收通过。

## BG-D20：无干扰边界与交付

完整的中间两轮都记录激活事件 0、候选激活事件 0、前台前后相同、指针端点相同。但最终轮记录 **activationEvents=1、ownActivationEvents=1、frontSame=false、pointerEndpointsSame=true**；后半部分几个静态步骤 active=true，所有步骤 key=false。没有调用 activate 或 makeKey，仍不能因此忽略候选实际被激活的事实。现有监测不能确定事件由用户、系统还是其他路径触发，**不宣称本轮全程零干扰**，并将其列为后续隔离回归问题。

问题 → 方案 → 后续：默认颜色空间漂移已有可复现证据，受控 SceneKit 时间回放已有正向样本；原生玻璃仍失败、真实多层同帧和候选激活来源尚未解决 → 保留显式颜色与显式时间作为实验候选 → 后续需要在真实共享 Renderer 中复验颜色和时间，并隔离激活来源；本轮不接入正式工具，不改变后台 nativeClick 契约，PV-T02／PV-T03 不放行。

验证与卫生：临时 Swift 探针实际编译退出 0，采用结果的完整运行均写出 report.json；最早的断言失败进程也可能退出 0，因此不把进程退出码当成实验成功。共享源码守卫实际输出 `共享源码守卫通过：33 个核心类型各一处定义，预览 target 编译宿主源码`。主控看过上述颜色、玻璃与动画图，文档链接和 git diff --check 通过。仓库只增补实验记录、台账和索引；未修改正式 Swift、系统显示设置，未运行宿主全量 build／unit，未启动真实媒体、提交或推送。候选、脚本、PNG、JSON 和日志全部放系统临时目录，核验后清理，保留用户既有修改。
