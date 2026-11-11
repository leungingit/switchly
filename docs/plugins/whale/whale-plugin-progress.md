# 鲸娘 Dock 预览插件 — 进度与续接手册

> 更新：2026-10-30。分支：`feat/plugin-scene-api`。设计提案见 [dock-preview-plugins-design.md](../dock-preview-plugins-design.md) §8、台账 D10 / D11（仍待裁决）。
> 本次仅更新独立小样的实测进度；完整插件尚未完成。天气分支已有通用 Scene 实现，后续必须复用并对齐，不能再造同用途引擎。

## 1. 目标

在 Dock 预览浮层里用「鲸娘」角色做动作：拉一条横幅，横幅显示当前 agent 会话的运行中数与已完成未读数。
宿主（Switchly）只提供通用 SDK / API，不内置任何角色或会话逻辑；角色资产、时间线、读取会话状态全部在插件里完成。

## 2. 已定决策与实测结论

| 编号 | 日期 | 结论 | 状态 / 依据与影响面 |
|---|---|---|---|
| M01 | 2026-10-29 | see-through 只做素材拆层，不含绑定与动画；动画由分层时间线完成 | 已定；工具说明明确不是 Image-to-Live2D |
| M02 | 2026-10-29 | 宿主新增通用 `scene`，声明图层与关键帧，宿主本地播放，不逐帧过 JS，带资源预算 | 先演示再定；小样进度见 M10，天气分支差异见 M13，D10 尚未裁决 |
| M03 | 2026-10-29 | 外部状态采用用户一次性授权目录只读 `fs.read`，不要求外部程序配合；inbox 方案被否决 | D11 待确认；未读取真实会话文件 |
| M04 | 2026-10-29 | 角色是用户提供的蓝发、鲸鱼鳍耳、女仆装 Q 版形象，不是 DeepSeek 图标 | 已定；公开发布前需确认形象版权 |
| M05 | 2026-10-29 | 展示在窗口条下方 `center` 卡片，高约 180pt | 已定；小样实际尺寸已查看，真实 Dock 布局未验 |
| M06 | 2026-10-29 | 横幅使用图标与数字，如 `▶ 3`、`● 2`，不放长句 | 已定；小样使用固定演示值 |
| M07 | 2026-10-29 | 横幅为独立图层，文字由宿主绘制；去除立绘中的原始白布 | 已定；小样已实现 |
| M08 | 2026-10-29 | 小样先在系统临时目录验证，通过后再迁仓库 | 已定；素材与可执行文件均未入库 |
| M09 | 2026-10-30 | v1 / v2 推理均完成；v1 五官空层较多，采用 v2，整理为 12 张裁剪 PNG 与文字层 | 替代此前「权重下载中 / 拆层未开始」进度；解码字节 6,636,120，最大单张 875×803 |
| M10 | 2026-10-30 | 原生 CALayer 小样已验证待机、展开、保持、收起、眨眼、浅深背景与减少动态效果静帧 | `swiftc` 编译；`--shots` 输出 `PASS staticFrames=9 reducedMotionAnimations=0`；九状态汇总与 24 帧运行时图层取样均已实际查看。属于独立小样，不能代表 Dock 集成通过 |
| M11 | 2026-10-30 | 旧 HTML 横幅单独缩放，过渡帧与手分离；原生版由双手旋转后的握持点推导横幅位置与宽度 | 覆盖旧 HTML 动作可用判断；361 点最大横向误差 `1.1368683772161603e-13` 源图像素，只是模型空间几何验证 |
| M12 | 2026-10-30 | 小样显式暂停、恢复、减少动态效果分支、关闭清理通过；进程资源采样较低 | `pauseDrift=0.0`，`layersDetached=true textureReferencesReleased=true`；启动 CPU 最高 5.2%，随后采样 0–0.6%，载入后内存 39–40 MB；两个角色同时播放。不包含 GPU / WindowServer，屏幕帧率未验 |
| M13 | 2026-10-30 | 天气分支 `e63c3fc` 已有通用 Scene，使用 Canvas / TimelineView；与 CALayer 提案存在渲染路径和预算差异 | 依据该分支 `../scene-api-alignment.md`；后续沿现有引擎扩展，先明确纹理预算、后台解码、可见性和播放路径，不并行重写 |
| M14 | 2026-10-30 | 头饰顶部平切来自拆层工具头部裁剪余量不足，原图完整；小样已从源图补顶 | 源图区域 x=500..760、y=160..215；最终图已查看。正式流水线需修裁剪策略；不改远端工具代码来掩盖原始问题 |
| M15 | 2026-10-30 | 现有 Scene 不能直接承载常驻立绘：只有一次性 `sprite`，减少动态效果时会跳过；需补通用静态图片能力 | 天气分支 `Sources/Models/Plugins/PluginScene.swift:338` 与 `Sources/Views/PluginSceneDrawing.swift:130`；`SceneAssets` 首次同步读图且无尺寸 / 内存预算。迁移前应复用该入口补能力，不能用无限延长精灵播放绕过静态图片缺口 |
| M16 | 2026-10-30 | 鲸娘插件 v0 已在 scene 分支实现：`Resources/Plugins/com.switchly.whale`，三种动作（待机打盹 / 拉横幅 / 忙碌）由运行中、未读数决定；引擎新增 `image` 图层与纹理预算（D15） | 单测通过，浅深色快照已查看；会话数暂由设置项演示，`fs.read` 未做，真实 Dock 悬停、帧率与 GPU 成本未验 |

原始尺寸估算为 1448×1086；最终小样使用 1280×1280 画布与裁剪素材。180pt 仅在独立小样中核验，不能将最初估算当作真实 Dock 测量。

## 3. 当前进度

| 项 | 状态 | 说明 |
|---|---|---|
| see-through v1 / v2 推理 | 完成 | 原始 PNG / PSD 保留在临时目录 |
| 逐个检查、部件合并与修补 | 完成小样版 | 去掉 nose 灰点，补头饰顶，睁闭眼独立，横幅独立；手臂仍为刚性部件旋转 |
| HTML 小样 | 已被原生版取代 | 原中间帧握持错误见 M11，不再作为通过证据 |
| 原生 CALayer 小样 | 部分自验通过 | 动作静帧、图层取样、几何、生命周期与进程 CPU / 内存通过；屏幕帧率与整机合成成本未验 |
| 通用 Scene | 天气分支已有实现 | 本分支仅提案；应复用天气分支，差异见 M13 |
| 纹理预算、后台解码、遮挡暂停 | 未完成宿主集成 | 当前小样满足纹理草案预算，不等于宿主门禁已实现 |
| `fs.read` 桥 | 未实现 | D11 待裁决；真实私密目录读取需单独授权 |
| 会话状态解析 | 未实现 | 未查真实状态文件，数字为固定 3 / 2 |
| 鲸娘插件、真实 Dock 与主题/玻璃验收 | 未实现 / 未验证 | 完整需求尚未交付 |

历史进度（2026-10-29）：曾记录「权重下载中、拆层与小样未开始」。该状态已被 M09 / M10 取代，保留此说明以免旧续接流程被误用。

## 4. 素材与环境

本轮原生验证直接在当前 macOS arm64 机器执行（Xcode 27.1 / Swift 6.4），没有再次远程到 `tailscale-macos`。

本地临时目录 `/tmp/whale-96IdEu/`：

| 相对路径 | 内容 |
|---|---|
| `out1/`、`out2/` | 原始 v1 / v2 PNG、PSD 与元数据 |
| `parts-v3/` | 12 张裁剪后的 RGBA PNG 与坐标 / 解码预算 `scene.json` |
| `prepare-v3.py` | 部件合并与补顶脚本；使用远端已有 PIL 环境执行 |
| `WhalePrototype.swift`、`WhalePrototype` | 原生小样源码、可执行文件 |
| `native-shots/static-contact.png` | 九状态静态汇总，已实际查看 |
| `presentation-shots/contact.png` | 24 帧运行时图层取样汇总，已实际查看 |
| `whale-native-preview.mp4` | 24 帧、4fps、6 秒离散取样预览；不是 30fps 屏幕录制 |
| `benchmark-final.log`、`top-final.log` | 最终生命周期断言、15 次进程资源采样 |
| `自验与续接记录.md` | 详细命令、失败与修复、证据边界 |

远端 `gpu-tail:/tmp/switchly-whale/` 保留 `see-through/`、`env/`、`hf/`、`ref/`、`out/`、`out2/` 与 `parts-v3/`。模型缓存已下载完成，约 12.8 GB；最近一次记录可用磁盘约 38 GB，续接前需重新检查。原来的「缓存约 1.9GB、仍在下载」记录已被 M09 取代。

临时目录可能在重启或系统清理后消失；这些路径仅供当前机器续接，不是仓库可复现夹具。素材尚未迁入仓库；本轮为继续复核而保留临时文件，清理项未完成。

## 5. 小样验证证据

实际执行：

```sh
swiftc /tmp/whale-96IdEu/WhalePrototype.swift \
  -o /tmp/whale-96IdEu/WhalePrototype -framework AppKit -framework QuartzCore

/tmp/whale-96IdEu/WhalePrototype /tmp/whale-96IdEu/parts-v3 \
  /tmp/whale-96IdEu/native-shots --shots

/tmp/whale-96IdEu/WhalePrototype /tmp/whale-96IdEu/parts-v3 \
  /tmp/whale-96IdEu/presentation-shots --capture

/tmp/whale-96IdEu/WhalePrototype /tmp/whale-96IdEu/parts-v3 \
  /tmp/whale-96IdEu/native-shots --benchmark
```

关键输出：

```text
PASS geometry samples=361 maxGripError=1.1368683772161603e-13 decodedBytes=6636120
PASS staticFrames=9 reducedMotionAnimations=0
PASS pauseDrift=0.0
PHASE reducedMotion t=21
PHASE closed t=26 layersDetached=true textureReferencesReleased=true
PASS lifecycle elapsed=31.834545999998227
```

生命周期清理最初触发隐式 `contents` 动画，导致断言失败；禁用隐式动画并显式移除动画后复测通过。静帧最初受 AppKit 上一帧缓存影响，最终改为模型层 `render(in:)`，修正坐标翻转后重新生成并查看。

窗口截图命令返回 `could not create image from window`。没有改为截取用户整个桌面。运行时证据改为从两套场景的 26 个 presentation 图层取样；这不能证明屏幕达到请求的 30fps，也不能反映真实玻璃材质与桌面透射。

## 6. 续接与验收边界

1. 沿已有 Scene 引擎对齐 D10：复用图层、轨道、求值与资源入口。先明确 Canvas 与 CALayer 的差异，再补有必要的宿主能力；不把一次原型证明扩展成通用性能保证。
2. D11 与动画引擎独立推进。真实状态目录读取涉及私密内容，需授权后再检查格式；宿主不得内置任何 harness 路径或解析规则。
3. 完成宿主与插件后，运行 `make build`、`make test-unit`，补资源预算、取消、可见性与权限回归；再做真实 Dock 悬停、浅深色、跟随系统与玻璃开关验收。
4. 系统减少动态效果通知、真实面板可见性 / 遮挡通知、后台解码 / 缓存与并发 Scene 预算尚未在鲸娘流程验证。
5. 素材目前是原型级刚性部件动画；不能将其描述为骨骼绑定或完整 Live2D。公开发布前仍需处理形象授权。

工作区隔离：本次进度文档在独立工作树 `Switchly-whale-wt` 更新。共享主工作区是 `feat/weather-gacha-music-plugin`；其中已有 `DockPluginOverlayModel.swift` 与设计文档修改，均保留。没有切换共享工作区分支、提交、推送或读取密钥 / 会话内容。
