# 插件 3D 渲染能力方案对比（2026-11-06）

> 状态：架构选型结论已明确（C-D01），产品验收及正式插件契约未通过；本文不修改现行插件契约，也不表示已实现 `scene3d` 或自由渲染层。
>
> 背景：音乐插件的 iPod 交互原型需要封闭且较薄的机身、白色正面、金属侧边和背板、随旋转变化的反射、实时歌曲屏幕及鼠标旋转。后续插件应能自行制作其他 3D 组件，无须宿主为每种造型新增专用代码。

## 1. 现状与不可混淆的边界

- 音乐插件在 JavaScriptCore 中执行 `render()`，返回 `screen`、`wheel` 等声明式节点；宿主在 SwiftUI 中绘制。媒体数据来自 `ctx.media.nowPlaying()`，操作经 `onAction` 返回插件。参见 [插件 API](plugin-api-reference.md) 与外仓 `plugins/com.switchly.music-controls/main.js`。
- 现有 `scene` 是宿主绘制的二维声明式动画；它不提供透视、三维网格或物理材质。[原设计台账](dock-preview-plugins-design.md) 的 D03 决定首期不开放 Canvas / WebView 自由绘制；D12 将例外明确为宿主播放的声明式 `scene`。本文只提出下一阶段的选择，不静默取代这两项裁决。
- 当前 iPod HTML 原型使用 Three.js/WebGL、Canvas 屏幕贴图和浏览器指针事件。JavaScriptCore 不提供它依赖的 DOM、Canvas 和 WebGL；原型不能直接当作现行插件代码运行。
- 原型中旋转时的屏幕条纹曾与近乎共面的 LCD/画面以及透明混合有关。它说明屏幕深度关系和纹理合成是验收项，并不证明某一种框架天然不会撕裂。

**共同目标**：新造型由插件独立交付；宿主只在新增平台能力时升级。下文的“受限”限制的是绘制指令和资源范围，不应把可选造型限制为宿主内置的 iPod 枚举。

## 2. 两种平台路线与 A 的一种候选实现

### A. 通用受限 `scene3d`（能力边界）

宿主提供一次性的 3D 加载、校验、渲染、动态表面、输入与生命周期能力。插件包提供模型、贴图及声明，指定命名网格作为屏幕和命中目标；`render()` 提供当前数据与动作 ID。宿主不含 `classicMusicPlayer` 等设备专用分支。与现有二维 `scene` 分开定义，避免改变其语义。

示意（**非现行 API，字段尚待技术验证**）：

```js
{
  type: "scene3d",
  key: "player",
  asset: "assets/player.glb",
  camera: { preset: "product", yaw: -20, pitch: -8 },
  interaction: { rotate: true },
  surfaces: [{ target: "lcd-content", content: {
    title: np.title, artist: np.artist, artwork: { mediaArtwork: true }
  } }],
  hits: [
    { target: "wheel-previous", id: "previous", label: ctx.t("Previous") },
    { target: "wheel-play", id: "toggle", label: ctx.t("Play") }
  ]
}
```

模型格式、材质子集、屏幕内容布局和参数名必须经 macOS 12 真机及预览工具验证后确定。若“动态表面”只能排版这一种屏幕，它就没有达到通用目标；至少应允许有界的文字、图像、进度和基础形状，并由插件指定在模型的哪个表面显示。

### B. 插件自由渲染层（Web 运行时 / WKWebView）

插件拥有画面的每帧绘制逻辑。对当前原型，最直接的实现是宿主承载插件包内的 HTML/Three.js，并通过受控桥接传递媒体快照、动作和生命周期。它需要一个浏览器渲染环境，例如 WKWebView；不是给现有 JavaScriptCore 增加一个普通 UI 节点就能运行 Three.js。

“自由层”仍有不同实现：宿主进程内的网页视图最接近原型；独立渲染进程可加强故障隔离，却增加 IPC、画面合成和输入转发成本；开放原生 GPU 命令或着色器则是另一套 API，不能复用 Three.js 原型。以下比较以 **插件包内 HTML/Three.js + 宿主承载** 为 B 的基准，其他形式需要单独验证。

### C. glTF 资产 + 宿主 2D 动态表面（A 的候选实现）

这是 A 在资产格式与动态表面上的一种实现选择，并非与 A 互斥的第三种平台架构。目标是由插件交付模型，宿主承载渲染、输入和表面内容；以下实现仍待验证：

1. **3D 资产**：候选格式为 **glTF 2.0（.glb）**，插件可用 Blender 或 Three.js 工具链制作。当前系统原生加载器不能直接导入本次测试的 glb；需要评估第三方加载器、受控转换流程或其他可验证的资产格式，并明确材质、扩展及 macOS 12 支持子集。
2. **2D 动态表面**：候选做法是把插件声明的文本、图像等内容离屏绘制并绑定到模型中的唯一屏幕网格。现有 `PluginUINode` 只负责宿主 SwiftUI 界面，尚无通用离屏纹理接口；需要定义尺寸、更新、色彩、UV、裁切、材质实例和释放规则。屏幕语义还须另建可访问性表示。
3. **交互**：候选做法是由宿主管理旋转与命名网格拾取，动作交给 `onAction`。拖动与点击阈值、遮挡、背面防误触、键盘路径和减少动态效果都需在真实面板内验证。

```js
// 方案 C 示意：字段、资产加载和离屏渲染均非现行 API
{
  type: "scene3d",
  key: "player",
  asset: "assets/ipod.glb", // 包含标准 PBR 材质与命名网格
  camera: { preset: "product", yaw: -20, pitch: -8, allowRotate: true },
  surfaces: [{
    targetMesh: "mesh_screen", // 精确指向唯一显示网格；绑定方式待验证
    resolution: [320, 240],
    content: {
      type: "vstack",
      children: [
        { type: "text", text: np.title, font: "headline" },
        { type: "text", text: np.artist, font: "caption" }
      ]
    }
  }],
  hits: [
    { targetMesh: "mesh_wheel_play", action: "toggle" },
    { targetMesh: "mesh_wheel_prev", action: "previous" }
  ]
}
```

## 3. 详细对比（C 是 A 的候选实现）

| 维度 | A：受限 `scene3d` 能力边界 | C：glTF + 2D 表面的候选实现 | B：插件自由渲染层 |
| --- | --- | --- | --- |
| 插件自主造型 | 插件交付资产，宿主不按设备类型分支 | 以 glTF 模型和命名网格表达；格式及支持子集待锁定 | 插件控制几何、材质和逐帧绘制 |
| iPod 迁移 | 需要资产、表面与动作合同 | 原型运行时几何要先导出或重建为资产；现有原型无 glb | Three.js 代码可部分迁移，仍需媒体桥与生命周期适配 |
| 动态屏幕 | 宿主提供有界表面能力 | 需新建离屏栅格化与纹理更新链路；现有 SwiftUI 节点不能直接作为纹理接口 | 插件自行绘制和更新屏幕 |
| 写实材质 | 由宿主声明支持范围 | 金属反射、clearcoat、环境贴图与色彩须逐项验证；原生 glb 直接加载已失败 | 可继续使用原型中的 Three.js 材质与光照实现 |
| 输入和无障碍 | 宿主负责输入预算及语义 | 需实现网格拾取、旋转、背面规则和独立语义路径 | 需定义 Web 与宿主的输入及语义桥 |
| 性能和故障 | 宿主可限制资源与可见性；具体效果待测 | 加载器、纹理上传、GPU 合成和多卡片资源均待实测 | 需实测 Web 进程、GPU、透明合成和脚本故障恢复 |
| 隐私 | 沿用本地插件资源约束 | 加载器及资产引用须禁止外部资源 | 需额外约束导航、网络、脚本来源和桥接 |
| 首期工程量 | 取决于选定的资产和表面能力 | 包括 glb 加载或转换、材质兼容、离屏表面、拾取与预览；尚无法定量 | 包括网页承载、桥接、生命周期、预览与隔离；尚无法定量 |

本表是实现范围比较，不构成能耗、内存、首帧或视觉质量的实测结论。

### C-V01：以当前 iPod 原型验证资产加载前提（2026-11-06）

**样本**：`/Users/liangkaijun/.codex/visualizations/2026/11/06/01a1ae92-f963-7152-9dba-6001efaebce8/ipod-prototype.source.js`。源码用 `ExtrudeGeometry` 生成机身，以 `MeshPhysicalMaterial` 表达白色正面、金属侧边和背板，用 CanvasTexture 绘制屏幕，`requestAnimationFrame` 持续渲染；没有现成 `.glb` 或可直接交给宿主的 2D 节点树。原型的点击按屏幕坐标与偏航角粗略判断，并非网格射线拾取。

**最小加载探针**：在系统临时目录生成最小 glTF 2.0 二进制文件，含一个三角形、一个命名网格和一个 metallic-roughness 材质；用当前 Xcode 的 Swift、Model I/O 和 SceneKit 读取。这个文件只检验格式入口，不代替真实 iPod 资产验证。实际输出：

```text
$ xcrun swift /tmp/switchly_c_probe.swift
canImport glb: false
canExport glb: false
MDLAsset objects: 0
SCNScene loaded: false
```

SceneKit 同时输出 `Could not load asset with unknown extension ... .glb`。**C-V01 结论**：当前环境中的 Model I/O 与 SceneKit 不能按文档原设想直接承载 glb。这个探针验证的是格式加载入口，不证明第三方加载器或转换流程不可行，也不代表 macOS 12 的行为。原型本身尚未导出为 glb；因此 iPod 材质一致性、动态屏幕、视觉无撕裂、旋转命中、VoiceOver、面板透明合成和性能均**未验证**。任何“零帧”“极小内存”或 Web 固定内存数值都没有本项目证据。

**后续技术门槛**：选定可在 macOS 12 运行的资产加载或转换路径，用从原型导出的完整机身资产测命名网格、PBR/clearcoat、UV 和正反面；再把真实媒体内容经新建的离屏表面链路贴到唯一屏幕网格，在宿主真实面板内检查正面、斜侧、背面和拖动。记录首帧、空闲、拖动、多卡片的 CPU/GPU/内存，再与 B 的同场景样本比较。只有两个不同造型的插件不改宿主造型代码即可工作，才能支持通用性判断。

### C-V02：以 iPod 几何近似样本验证 USD 路径（2026-11-06）

用 Blender 5.2.2 按原型机身宽高厚度、正面、金属背板、屏幕和转盘结构制作**管线样本**，分别导出 `.glb` 和 `.usdc`，再用系统 `usdzip` 打包 `.usdz`。这不是从 Three.js 原型无损导出：圆角、贴图、clearcoat、环境反射和细节尚未复现，也不是最终 iPod 美术资产。样本有 7 个网格，屏幕单独命名为 `mesh_screen` 并采用完整 UV 平面。命令为 `blender -b -noaudio --python <临时建模脚本>`、`usdzip /tmp/switchly_c_ipod.usdz /tmp/switchly_c_ipod.usdc`、`xcrun swift <临时加载探针>`；临时脚本和模型在验证后清理。实际输出摘要：

```text
FORMAT glb bytes=169388 canImport=false
MDL count=0
SCN error=... switchly_c_ipod.glb ... could not be opened
FORMAT usdc bytes=91397 canImport=true
MDL count=1
SCN mesh nodes=7
screen children=["Plane: true"]
child material=screen_dynamic
screen texture assignment=true
FORMAT usdz bytes=91560 canImport=true
MDL count=1
SCN mesh nodes=7
child material=screen_dynamic
screen texture assignment=true
```

用 `SCNRenderer.snapshot` 生成原生离屏画面，并实际检查了[正面](assets/3d-loading-probe-2026-11-06/front.png)、[斜侧](assets/3d-loading-probe-2026-11-06/side.png)、[背面](assets/3d-loading-probe-2026-11-06/back.png)。正面可见一张运行时生成的文字贴图，斜侧可见厚度，背面与正面不同；这些只证明 **USD 资产进入原生渲染器、命名节点可定位、单独屏幕材质可替换并出现于快照**。初版用薄盒当屏幕时，文字纹理未正常铺开；改成 UV 平面后才可见，因而目标网格的 UV 和朝向需要成为资产验收项。快照中的转盘与金属反射仍粗糙，不满足当前原型的写实目标。

**阶段结论 C-V02**：`USD（.usdc / .usdz）→ Model I/O / SceneKit → 运行时表面纹理` 是本机已运行的技术路径；`.glb → Model I/O / SceneKit` 仍不成立。若采用 USD，建议插件交付端在构建时转换与校验，再由宿主只加载经过验证的本地 USD 资产；`.usdz` 可作为单文件交付候选，但外部纹理及完整材质仍需实测。需要评估转换工具的可重复性、第三方插件发布流程和 macOS 12 兼容性。若坚持 glb 为插件包格式，则必须引入经评估的 glTF 加载或构建期转换工具，不能把系统原生框架当作现成 glb 加载器。

**未验证**：真实原型资产的 PBR/clearcoat 一致性、动态 SwiftUI 节点离屏栅格化、鼠标旋转与网格拾取、VoiceOver、减少动态效果、真实媒体桥、宿主面板合成、多卡片性能、macOS 12。当前快照是独立原生探针，不能充当插件预览或真实面板验收。

### C-V03：GLTFKit2 作为 glb 原生加载器候选（2026-11-06）

用户提出 [GLTFKit2](https://github.com/warrenm/GLTFKit2)。仓库 README 声明可从本地 glTF/glb 构造 `GLTFAsset`，再桥接为 `SCNScene`；`GLTFSceneKit.m` 的实际实现映射基本金属度/粗糙度、法线与 `KHR_materials_clearcoat` 到 SceneKit 材质。`Package.swift` 声明最低 macOS 11，符合 Switchly 的 macOS 12 部署目标；许可证为 MIT。当前检出的 `master` 为 `be89e833aa85bde67bd27d4ecff3b7816c58ce56`（2026-05-20）。[README 与能力清单](https://github.com/warrenm/GLTFKit2#status-and-conformance)、[包配置](https://github.com/warrenm/GLTFKit2/blob/master/Package.swift)、[SceneKit 桥实现](https://github.com/warrenm/GLTFKit2/blob/master/GLTFKit2/GLTFKit2/GLTFSceneKit.m)。

**评价**：GLTFKit2 比“所有插件先转换为 USD”更贴合插件作者常用的 glb 交付方式，也保留了宿主原生 SceneKit 渲染与动态表面路线。它解决的是 **glb 解析与 SceneKit 场景构建**，不自动解决 iPod 的环境反射、色彩一致性、屏幕纹理更新、网格拾取、无障碍或性能。README 明确承认实现尚未完全符合 glTF 2.0 规范；扩展对象被解析也不保证 SceneKit 完整呈现。当前 Swift Package 指向固定的 `0.5.15` 预编译 XCFramework，可能与 `master` 源码有差异，不能仅凭源码清单断言二进制包已支持全部材质。Draco 与 KTX2 另有可选依赖；首期应先限定未压缩几何与常规 PNG/JPEG 贴图。

**验证顺序**：在系统临时目录内固定具体 revision 或二进制版本，把 iPod 完整 glb 送入 `GLTFAsset → SCNScene`；逐项记录网格名称、UV、金属/粗糙度/clearcoat、外部资源引用及加载失败分支，再替换唯一屏幕材质并拍摄正侧背面。通过后测 macOS 12、宿主面板和多卡片预算。插件包资产须限定本地路径、大小、解码后资源量和所允许的 glTF 扩展；新增第三方依赖时按工程依赖约定处理。此处是 C-V03 时的待办；加载与离屏截图已由 C-V04 部分完成，完整资产及宿主验证仍待办。

### C-V04：固定 GLTFKit2 0.5.15 的 glb 加载实测（2026-11-06）

在系统临时目录创建 macOS 12 SwiftPM 命令行探针，依赖 `GLTFKit2` 的 `master`（解析为 `be89e833aa85bde67bd27d4ecff3b7816c58ce56`）；其 `Package.swift` 实际下载固定的 **0.5.15 XCFramework**。`swift build --package-path <临时探针目录>` 成功。命令行首次直接运行时报 `dyld: Library not loaded: @rpath/GLTFKit2.framework`；在临时探针指定 `DYLD_FRAMEWORK_PATH=<SwiftPM Products/Debug>` 后运行成功。正式 App 集成必须核对框架嵌入、签名及运行时路径，不能把此临时环境变量当作发布办法。

用 Blender 按原型的尺寸、薄封闭机身、白色正面、金属侧边和背板制作六网格[glb 管线样本](assets/3d-loading-probe-2026-11-06/ipod-gltfkit2.glb)（155316 字节）；其中白色正面和金属背板使用 `KHR_materials_clearcoat`，屏幕为有 UV 的独立平面。此样本仍非原型的完整精确导出。`GLTFAsset.load(with:) → SCNScene(gltfAsset:)` 的实测摘要：

```text
mesh back_metal material=metal_back uv=1 metal=0.72 rough=0.18 coat=1
mesh body_closed_metal material=metal_side uv=1 metal=1 rough=0.2
mesh front_white material=white_front uv=1 metal=0.06 rough=0.27 coat=0.9
mesh mesh_screen material=screen_dynamic uv=1 metal=0.05 rough=0.24
mesh count=6
screen texture assigned=true
front png bytes=30559
side png bytes=35809
back png bytes=96833
```

用 SceneKit 离屏渲染并实际查看了[正面](assets/3d-loading-probe-2026-11-06/gltfkit2-front.png)、[斜侧](assets/3d-loading-probe-2026-11-06/gltfkit2-side.png)、[背面](assets/3d-loading-probe-2026-11-06/gltfkit2-back.png)。正面文字经宿主探针生成的图像贴到 `mesh_screen`，侧面显示机身厚度，背面与正面不同。glb 的坐标轴与上一轮 USD 样本不同，探针需要调整相机朝向；未来插件合同应约定模型轴向与单位。简化转盘和反射尚不符合写实目标，屏幕内容也没有接入 Switchly 的真实媒体与声明式 UI。

**阶段结论 C-V04**：固定二进制 0.5.15 已在本机通过 glb 解析、命名网格、基础 PBR 与 clearcoat 数值映射、UV 和运行时屏幕贴图的离屏验证。它使 glb 成为比强制 USD 转换更有依据的优先资产格式候选；尚未验证完整 iPod、macOS 12 实机、原生面板、拖动拾取、无障碍、外部资源限制或多卡片性能。因此继续保持“候选”，不修改现行插件 API 或宿主工程依赖。

### C-V05：原型几何导出、表面更新与旋转命中（2026-11-06）

用与浏览器原型相同版本的 Three.js r186，抽取 `roundShape`、`slab`、机身三层、屏幕边框/LCD 与转盘几何及原有 `MeshPhysicalMaterial` 参数，经 Three.js `GLTFExporter` 导出[原型几何 glb](assets/3d-loading-probe-2026-11-06/ipod-source-geometry.glb)（487760 字节、11 个网格）。将原型的像素尺寸统一乘 `0.01`，避免 SceneKit 默认相机裁剪面吞掉模型。glb 包含 `KHR_materials_clearcoat`、`KHR_materials_emissive_strength` 和 `KHR_materials_unlit`。原型中以浏览器 Canvas 实时绘制的歌曲屏幕、转盘文字与背板刻字**不属于静态几何资产**；它们仍需宿主的动态表面能力。原型程序生成的反射环境也没有随 glb 导出，宿主需提供环境光贴图和色彩合同。

在系统临时目录用固定 revision `be89e833aa85bde67bd27d4ecff3b7816c58ce56` 对应的 GLTFKit2 0.5.15 二进制包运行 `GLTFAsset → SCNScene → SCNRenderer`，加载全部 11 个命名网格且每个都有一组 UV。生成屏幕图像时，SceneKit 贴图坐标与绘制图像的纵向约定不同；设置 `diffuse.contentsTransform` 的 Y 翻转和偏移后，文字正向显示。实际查看了[正面](assets/3d-loading-probe-2026-11-06/source-front.png)、[侧面](assets/3d-loading-probe-2026-11-06/source-side.png)、[背面](assets/3d-loading-probe-2026-11-06/source-back.png)及[换歌后正面](assets/3d-loading-probe-2026-11-06/source-screen-updated.png)。

通过 `SCNRenderer.hitTest` 对同一屏幕坐标取射线、旋转模型而不移动相机，实际输出：

```text
MESH_COUNT 11
HIT front screen ["mesh_screen"] wheel ["mesh_wheel_play", "mesh_wheel_play"]
HIT side screen ["body_closed_metal", "body_closed_metal"] wheel ["body_closed_metal", "body_closed_metal"]
HIT back screen ["back_metal", "body_closed_metal", "back_metal"] wheel ["back_metal", "body_closed_metal", "back_metal"]
SCREEN_UPDATED 32724 differentFromFront true
```

首次导出时，一个透明且 `opacity: 0` 的 `wheel_labels` 平面仍会被射线拾取；移除该占位平面后得到以上结果。宿主命中合同必须按**首个可见表面**和允许交互的命名网格过滤，不能因为材质透明就假定网格不会拦截事件。正面点击路由与背面防误触在独立探针里具备可实现证据；鼠标拖动手势、惯性、触控板、键盘和 VoiceOver 尚未验证。

**阶段结论 C-V05**：原型的封闭薄机身、白色正面、金属侧背、屏幕网格与转盘几何可作为 glb 从 Three.js 工具链进入 GLTFKit2/SceneKit；动态屏幕贴图、模型旋转和基于网格的正背面命中在独立原生探针中成立。当前快照的金属反射和转盘细节仍逊于浏览器原型；环境贴图、真实 2D UI、插件包资源校验、第二种造型、macOS 12 实机及宿主面板的视觉/性能验收仍是方案 C 的未通过项。此结论**不等于**现行插件已具备 `scene3d`。

### C-V06：独立 AppKit 面板合成与鼠标事件路径（2026-11-06）

在系统临时 SwiftPM 工程中使用同一[原型几何 glb](assets/3d-loading-probe-2026-11-06/ipod-source-geometry.glb)、GLTFKit2 0.5.15、`SCNView` 与 `NSPanel`／`NSVisualEffectView` 创建可见的原生面板。部署目标为 macOS 12，但实际运行于当前机器。通过 `screencapture -l <windowID>` 截取真实 WindowServer 窗口；命令返回 `front/side/back/dragged status=0`。已实际查看[正面](assets/3d-loading-probe-2026-11-06/panel-front.png)、[拖动后](assets/3d-loading-probe-2026-11-06/panel-dragged.png)、[侧面](assets/3d-loading-probe-2026-11-06/panel-side.png)、[背面](assets/3d-loading-probe-2026-11-06/panel-back.png)：白色正面、薄金属侧边、金属背板和文字屏幕在真实窗口合成中可见；静态图未见屏幕条纹。它们不证明连续旋转过程无撕裂。

面板 `SCNView` 接受 AppKit 鼠标事件，水平拖动改变模型偏航角；探针向 `NSPanel.sendEvent` 发送模拟鼠标按下、拖动与抬起以检查窗口分发和拾取，实际输出：

```text
CLICK target=mesh_wheel_play
DRAG yaw=1.559999942779541
CLICK target=back_metal
```

该输入验证覆盖 **AppKit 窗口事件分发到视图**，没有通过真实鼠标硬件或 Accessibility 发起操作；也未验证滚轮、触控板、惯性、键盘和减少动态效果。此面板是独立进程，不是正式 Switchly Dock 插件面板，也没有使用现行插件 UI 解码器或真实媒体桥。现有预览契约要求复用宿主渲染实现，故不能将独立探针截图冒充插件预览通过。面板尺寸和背景材质也不同于正式插件槽位。

**阶段结论 C-V06**：glb/GLTFKit2/SceneKit 在可见原生窗口内的加载、合成、旋转、正面点击和背面防误触有可运行证据。正式接入前仍需先裁决并版本化 `scene3d` 资产、表面、动作和资源预算合同，再让宿主与预览编译同一渲染组件；真实槽位视觉、连续旋转视频、系统输入、macOS 12 和多卡片性能仍未通过。

### C-V07：第二种造型、资源样本与资产引用边界（2026-11-06）

用 Blender 生成与 iPod 外形不同的[圆形气压计 glb](assets/3d-loading-probe-2026-11-06/barometer.glb)：黄铜圆壳、表盘、指针及独立 `mesh_weather_screen`，共 4 个网格。与 iPod 一起使用同一 `GLTFAsset → SCNScene → SCNRenderer` 代码加载；仅资产路径、表面名称与相机位置由样本配置决定。实际输出包括 `SCENE 0 ipod meshes 11 surface true`、`SCENE 1 barometer meshes 4 surface true`。已查看[气压计原生快照](assets/3d-loading-probe-2026-11-06/barometer.png)和[增加环境图像后的 iPod 快照](assets/3d-loading-probe-2026-11-06/ipod-with-env.png)。第二种造型没有要求添加设备专用渲染分支，说明 **资产和命名表面可泛化到另一外形**；但该样本只有静态指针，未验证动态表面的排版或命中动作。环境图像下的金属仍未达到浏览器原型的写实反射。

同一命令行探针以 `/usr/bin/time -l` 在当前机器的热缓存条件下顺序运行，单场景输出 `LOAD_MS 90`、`RENDER_MS 116`、最大驻留集 `46579712` 字节；四场景（iPod、气压计各两份）输出 `LOAD_MS 49`、`RENDER_MS 129`、最大驻留集 `53788672` 字节。加载时间反而下降，说明缓存和 GPU 初始化影响显著；这些数字只描述本机短命进程与 512×512 离屏快照，**不能作为真实常驻面板首帧、能耗或多卡片预算通过证据**。

资产边界实验在临时插件模型目录内生成一个 glb，其图片 URI 为 `../../sentinel.png`，目标是本次测试自行创建的无敏感内容 PNG。GLTFKit2 0.5.15 完成加载并返回 `imageURI=file:///tmp/switchly-c-decision/plugin/assets/../../sentinel.png`。这证明模型内部引用可解析为模型目录外的路径；现有 `PluginPackageValidator` 的 32 MiB 包大小和禁符号链接检查不检查 glb 内部 URI。正式能力必须在调用 GLTFKit2 **之前**解析并校验 glb JSON：首期仅允许自包含二进制缓冲和嵌入图像，拒绝所有外部 `buffer.uri`、`image.uri`（除经限定的数据 URI）、未知或未批准扩展，并限制解码后网格、顶点、纹理像素及总 GPU 预算。此探针没有验证第三方库会读取任意外部文件，不能据此宣称已发生私密信息读取。

## 4. 容易低估的共同工作

1. **真实媒体与状态**：iPod 必须使用现有媒体 API 的歌曲、封面和播放状态；JS 不应通过逐帧轮询媒体来驱动屏幕。状态变化后更新内容即可。
2. **拖动与控件区分**：旋转过程留在渲染端本地，只有有效控件点击进入 `onAction`；命中区域须随模型一起旋转，背面不可误触正面控件。
3. **屏幕深度**：优先让画面成为模型内唯一的显示面，避免两个近乎共面的半透明内容面造成闪烁。检查正面、斜侧、接近侧面及连续旋转。
4. **窗口生命周期**：隐藏、卸载或切换目标时停止帧循环并释放资源；减少动态效果时取消惯性运动，保留可用的直接操作。
5. **可访问性**：画面之外仍要有歌曲信息、控制动作及视角操作的语义路径。
6. **资源来源**：无论选择哪一方案，插件资产路径、大小和解码后的资源成本都要有界；新增网络行为不能由渲染层绕开现有隐私合同。

## 5. 裁决建议与退出条件

**C-D01｜架构选型结论（2026-11-06）：方案 C 可以作为下一阶段 3D 插件能力的首选实现路线。** 选用“插件交付受限、自包含的 glb + 宿主统一加载、动态表面、输入与生命周期”的方向，以 GLTFKit2/SceneKit 为首个实施候选；USD 保留为加载对照。C 是 A 的具体实现，不新增 iPod 专属宿主类型。该结论取代本文先前“C 只能作为待裁决假设”的建议，保留 C-V01～C-V07 的原始证据与限制。

| 判断 | 结论与证据 |
| --- | --- |
| 新造型能否由插件交付 | **可作为首选**：iPod 11 网格与气压计 4 网格使用同一加载和渲染路径；后者只更换资产与配置。 |
| glb、动态表面、旋转与命中是否可实现 | **可作为首选**：C-V04～C-V06 已在离屏和独立 AppKit 窗口中运行；屏幕更新、正面按钮和背面防误触有实测。 |
| 是否满足当前 iPod 完全写实目标 | **未通过产品验收**：反射、转盘细节、Canvas 屏幕布局尚未达到原型；连续旋转与真实媒体未验。 |
| 是否可立即开放给任意插件 | **不可**：C-V07 的模型内部 URI 边界需加载前封堵；还要确定解码资源预算、第三方框架嵌入及版本兼容。 |
| 是否已在真实 Switchly 槽位通过 | **未通过**：尚无正式 `scene3d` 合同及共享宿主/预览实现；macOS 12、无障碍、多卡片常驻成本待实测。 |

**裁决的实际含义**：优先投入 C 的合同和宿主纵向切片；不要以当前实验截图宣称可发布或完全写实。若纵向切片无法在事先锁定的视觉与资源预算内通过，应停止扩大 SceneKit 特例并重新比较 B。现行 D03/D12 与 `PluginUINode` 语义保持有效；采用 C 的正式 API 仍须在主设计台账与公开契约中另行编号、版本化并实施。

**后续实施**见[`scene3d` 方案](plugin-scene3d-implementation-plan.md)与[子任务书](plugin-scene3d-tasks.md)。C-D01 已取代上文历史阶段中“仅在 iPod 与第二样本通过真实面板后才考虑 C”的选型门槛；真实面板、视觉、无障碍与资源预算现在是实施后的产品 Go/No-Go 门禁。若 C 无法满足关键样本，或扩充宿主材质、动画、动态表面与输入能力的代价超过受控自由渲染层，应重新评估 B。B 也必须在真实面板中验证首帧、透明合成、多卡片资源和离线边界。

## 6. 若进入实施，先锁定的契约与验收

1. 在 [插件设计台账](dock-preview-plugins-design.md) 新增经确认的裁决编号，明确 D03/D12 的保留或取代关系；同步 [API 参考](plugin-api-reference.md)、`Plugins/api/`、`Plugins/sdk/` 与 [预览契约](plugin-preview-contract.md)。本文本身不改现行合同。
2. 原生或网页渲染小样先在真实宿主面板内验证薄封闭机身、白色正面、金属侧边/背板、反射随视角变化、屏幕无条纹以及旋转和点击行为。原型的浏览器截图只作为视觉参照。
3. 记录正面、侧面、背面及拖动中的截图或视频，并分别测量首帧、空闲、拖动及多个卡片同时显示时的 CPU/GPU/内存；验收阈值在实施前确定，避免事后改标准。
4. 运行插件外仓 `npm test`、`npm run build`，宿主 `make build`、`make test-unit` 和适用的 `make plugin-preview-contract-check`；预览工具使用与宿主一致的渲染实现验收。

