# Scene API 双分支对齐说明

> 日期：2026-10-30。背景：`feat/plugin-scene-api` 提出 §8「Scene API 提案」（D10 / D11，均为「待确认」，只有文档、无实现）；`feat/weather-gacha-music-plugin`（PR #18）为把天气抽卡从原生 Swift 迁成 JS 插件，按用户裁决实现了通用的 `scene` 组件、`media.library` 与设置类型（D12–D14）。
> 本文记录两边差异、已实现范围与合并建议，供合并 §8 提案前裁决。

## 1. 两边现状

| | `feat/plugin-scene-api` | `feat/weather-gacha-music-plugin`（本分支） |
|---|---|---|
| 内容 | 设计文档 §8 提案 + 鲸娘插件进度手册（commit `1096985`） | 完整实现（解码 / 求值 / 绘制 / 视图）+ 内置抽卡插件 + 单测 + 文档 §9 |
| 代码 | 无（`git diff origin/main...` 仅 2 个 md 文件） | `PluginScene.swift`、`SceneEvaluator.swift`、`PluginSceneDrawing.swift`、`PluginSceneView.swift` |
| 验证 | 未验证 | `make build`、`make test-unit`（515 个通过）、`verify.sh` PASS、离屏逐帧快照人工核验 |

结论：**提案尚未实现，本分支是它的一次完整落地**；下面的差异是「实现时的取舍」，不是两边各写一套。

## 2. 逐项对照

### 2.1 节点与图层

| 提案 §8.2 | 实现（§9.2） | 说明 |
|---|---|---|
| `layers[]` 带 `parent`、`z` | `children` 嵌套，数组顺序即绘制顺序 | 嵌套天然表达父子变换；未提供跨父级的 `z`。层级越深预算越紧（深度 ≤ 6） |
| `anchor`、`pivot` | `anchor`（默认居中） | `pivot` 未单独提供：`anchor` 同时决定摆放原点与旋转 / 缩放中心，足够覆盖抽卡卡片的需求 |
| `asset` 或 `text` 两类图层 | `group / rect / ellipse / text / symbol / wave / emitter / sprite` | 增加了形状、符号、可拨弦的线、粒子、精灵图，用于在不开放逐帧 JS 的前提下表达抽卡动效 |
| `text` 只接受文本 + 预设样式枚举 | 同（`size`、`weight`、`design`、`italic`、`fill` 枚举 / 主题令牌） | 一致；文字颜色可用 `$label` / `$secondaryLabel` 跟随浅色深色 |
| `pluginAsset` 引用插件内图片 | `sprite.asset`（相对插件目录，拒绝 `..` 与绝对路径） | `image {pluginAsset}` 这一旧缺口未在此次补上，仍走占位图；抽卡的爆发精灵图用的是 `sprite` |
| `clips`：`x/y/rotation/scale/opacity` 关键帧，easing `linear / easeInOut / spring{stiffness,damping}` | `tracks`：同样的属性 + `w/h/scaleX/scaleY/blur/angle`，easing `linear / in / out / inOut / hold`，可 `loop` | **未实现 spring**。抽卡里需要弹簧感的段落（落地回弹、鞠躬）用 0.03 s 采样的关键帧逼近，视觉上不可分辨，但插件作者少一个便利工具 |
| `play: {clip, loop, hold, at}` | `scene: {key, epoch, width, height, fit, fps, restAt}`，循环放在每条轨道的 `loop` | 语义等价：`at` ↔ `epoch`（Unix 秒），`loop` ↔ 轨道级 `loop`，`hold` ↔ 轨道最后一帧保持 + `restAt`。命名不同，合并时应统一成提案的命名或反过来更新提案 |
| `onClipEnd` 回调 | 无 | 实现改用 `ctx.invalidate()` 主动刷新 + 宿主 1 s 轮询；抽卡不需要精确的动画结束回调。若鲸娘需要，再加 `onSceneEnd` |
| — | `osc`（振荡叠加：`amp/freq/phase/start/end/decay/wave`） | 提案没有。循环 + 衰减用关键帧表达代价很高（每条 60 Hz 采样），振荡器让「呼吸、心跳、闪烁」这类重复动作只写一行 |
| — | `hit {id, label, hoverScale}`、`showOnHover`、`shatter`、`wave.plucks` | 命中区域、悬停联动与两个专用效果层。前两者是通用交互能力；`shatter` / `plucks` 是为「卡片碎裂」「琴弦被拨动」抽象出的通用效果，不含抽卡字样 |

### 2.2 预算与隔离（提案 §8.3 vs 实现 §9.3）

| 项 | 提案 | 实现 | 差异影响 |
|---|---|---|---|
| 图层数 | ≤ 32 | ≤ 160 | 抽卡的实质是「五线谱 + 3 张卡 + 粒子 + 数字 + 按钮」，32 层装不下；160 仍远低于卡顿阈值 |
| 粒子 | 未列 | ≤ 400（单发射器 ≤ 120） | 新增；粒子在宿主侧按确定性哈希计算，不占 JS |
| 命中区域 | 未列 | ≤ 12 | 新增，供 VoiceOver 与点击 |
| 纹理 | ≤ 2048px、解码后 ≤ 32 MB | 未检查尺寸，仅缓存当前插件用到的精灵图 | **缺口**，合并前应补尺寸上限与 LRU（见 §3） |
| 帧率 | 默认 30、上限 60 | 10–60，插件自定 | 一致 |
| 同时活动 scene | ≤ 3 | 未限制 | 实际只有 Dock 预览一个面板，当前最多 1 个；补上限时顺带做 |
| 可见性 | 不可见 / 被遮挡时暂停 | 面板关闭即移除视图、时间线销毁、VM 卸载 | 实现用「销毁」而非「暂停」，更彻底；被遮挡（未关闭）时不暂停，是缺口 |
| 减少动态效果 | 显示 clip 末帧 | 显示 `restAt`（缺省为 `settledAt`，即最后一帧） | 语义一致；给了插件显式指定静帧的余地 |
| 资产解码 | 后台队列 + LRU，关闭释放 | 首次绘制时同步解码，随视图释放 | **缺口**：首次出现精灵图可能卡一帧；抽卡只有 3 张 6×4 精灵图，未暴露问题 |
| 异常 | 连续超时停用插件 | 沿用运行时既有软超时（连续 3 次停用） | 一致 |

### 2.3 与 D02 / D03 / D11 的关系

- **D03**：提案就已改为「不开放逐帧 JS 绘制，开放声明式场景」，实现遵守：JS 只在状态变化与 1 s 轮询时运行，绘制全在宿主。
- **D02**：`media.library` 是本分支新增的受限能力（只是挑歌 / 播放 / 暂停，AppleScript 由宿主生成），属于对 D02 的有据扩展，已记 D13。`fs.read`（D11）**未实现**，仍待裁决；它的只读沙箱、路径规范化、敏感目录拒绝等约束都还没落代码。
- **§8.5 S1 独立小样**：未做。原因：抽卡迁移本身就是一个真实用例，直接用离屏快照 + 逐帧计时代替了「另建最小工程」这一步；代价是**没有测量真实 Dock 悬停面板下的 CPU / 内存**（见 §4）。

### 2.4 实现路径与提案不一致之处（需要知情）

提案写的是「宿主在 Core Animation 合成线程本地播放」。实际实现是 **SwiftUI `Canvas` + `TimelineView`**，逐帧在主线程绘制：

- 优点：与现有 `PluginOverlayView` 的材质、主题、减少动态效果一致；无需管理 CALayer 树，命中测试与无障碍直接用几何计算。
- 代价：每帧绘制成本随图层与粒子数线性增长；场景越多越重。已用「停表」「预算」「减少动态效果静帧」压制，但**没有做过 CALayer 版本的对比测量**。

若后续鲸娘这类角色动画在真机上出现掉帧，优先尝试的路径是：把静止图层预渲染成位图、或把整段场景下沉到 CALayer（提案原方案），而不是提高预算。

## 3. 合并建议（按优先级）

1. **统一命名**：`scene.key/epoch/restAt` 与提案的 `play.clip/at/hold` 二选一，同步改文档与抽卡插件；这是纯机械改动，越早越好。
2. **补 `spring` easing**：提案明确要，实现在抽卡里用采样绕过了；补上后可以简化 `main.js` 里几段姿态采样。
3. **补纹理预算与 LRU**：尺寸上限、解码后总量、后台解码，都属提案已列但实现缺失的项。
4. **补并发 scene 上限与被遮挡暂停**：面板被遮挡时根据 `NSWindow.occlusionState` 暂停时间线。
5. **再裁决 D11（`fs.read`）**：与本分支无耦合，可独立推进；若推进，`Scene` 不参与，避免把文件能力与动画引擎绑在一起。
6. **`onSceneEnd`**：等鲸娘插件真正需要时再加，避免提前抽象。

## 4. 未验证项（两侧共有）

- 真实 Dock 悬停面板下的 CPU / 内存 / 掉帧情况：本分支只测了离屏渲染 + 编码 ≈ 10 ms/帧（上界，含 PNG 编码），**不能当成真实面板的帧耗时**。
- macOS 12：`Canvas` / `TimelineView` / `NSViewRepresentable` 均可用，但未在 12 上实跑。
- 鲸娘所依赖的角色资产、拉横幅时间线、会话计数来源，仍停留在提案阶段。
