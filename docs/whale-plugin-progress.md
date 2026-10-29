# 鲸娘 Dock 预览插件 — 进度与续接手册

> 日期：2026-10-29。分支：`feat/plugin-scene-api`。设计提案见 [dock-preview-plugins-design.md](dock-preview-plugins-design.md) §8、台账 D10 / D11（均「待确认」）。
> 本文记录进度、已定决策、远端环境状态与下一步，用于换机器后接着做。

## 1. 目标

在 Dock 预览浮层里用「鲸娘」角色做动作：拉一条横幅，横幅显示当前 agent 会话的运行中数与已完成未读数。
宿主（Switchly）只提供通用 SDK / API，不内置任何角色或会话逻辑；角色资产、时间线、读取会话状态全部在插件里完成。

## 2. 已定决策

| 编号 | 结论 | 状态 |
|---|---|---|
| M01 | see-through 只做素材拆层（不含绑定与动画，README 自述 not Image-to-Live2D）；动画由自研分层时间线完成 | 已定 |
| M02 | 宿主新增通用 `scene` 组件（声明图层 + 关键帧，宿主本地播放，不逐帧过 JS），带层数 / 纹理 / 帧率 / 并发预算 | 先做演示再最终确定 |
| M03 | 外部状态读取：用户一次性授权目录只读（`fs.read`），不要求外部程序配合；inbox 方案被否决 | 待确认（D11） |
| M04 | 角色形象为用户提供的「蓝发、鲸鱼鳍耳、女仆装 Q 版」参考图，不是 DeepSeek 图标；公开发布前需确认形象版权 | 已定 |
| M05 | 展示位置：窗口条下方 `center` 卡片，高度提到约 180pt（现有为 132pt） | 已定 |
| M06 | 横幅内容用图标 + 数字（如 `▶ 3`、`● 2`），不放长句 | 已定 |
| M07 | 横幅为独立图层，文字由宿主绘制；拆层后去掉立绘里的白布，用独立图层替代 | 已定 |
| M08 | 小样先在系统临时目录做，验证通过后再迁入仓库 | 已定 |

尺寸依据（估算，未在真实界面验证）：立绘 1448×1086，图内横幅约 890×150；132pt 高时缩放约 0.12，横幅仅约 108×18pt，文字太挤，故升到 180pt。

## 3. 进度

| 项 | 状态 | 说明 |
|---|---|---|
| 方案调研（see-through、动画技术选型） | 完成 | 结论见设计文档 §8 与上表 |
| 设计文档 §8、D10、D11 | 已写，待用户确认 | 本分支 |
| 参考图 | 完成 | 用户本机 `Pictures/tmp/43ba026568ce432d58651792d115de5942d9a01b.jpg`（不入库） |
| 拉横幅全身立绘 v2 | 完成 | 头顶完整，透明背景；顶部留白仅约 2%，合成时加内边距。不入库 |
| `gpu-tail` 环境 | 完成 | 见 §4 |
| see-through 首次推理 | **进行中** | 权重下载中，尚未出 PSD；首轮跑的是旧参考图，需对 v2 立绘重跑 |
| 拆层结果检查与部件合并 | 未开始 | 目标约 8 个部件 |
| 独立动画小样（HTML/Canvas） | 未开始 | |
| macOS 原生 CALayer 小样（CPU / 内存 / 流畅度） | 未开始 | 在 `tailscale-macos` 上做 |
| `scene` 组件与 `fs.read` 桥实现 | 未开始 | 小样通过后 |
| harness 会话状态文件位置与格式 | 未查 | 插件自行解析，需先看 harness 代码 |

## 4. 远端环境

| 主机 | 情况 |
|---|---|
| `tailscale-macos` | macOS arm64，Xcode 27.1、Swift 6.4，用于原生小样 |
| `gpu-tail` | Ubuntu 22.04，RTX 3090 24GB；根盘剩余约 29GB（2026-10-29 实测，持续下降，低于 15GB 先清理再继续） |

`gpu-tail:/tmp/switchly-whale/`（`/tmp` 重启后可能被清）：

| 路径 | 内容 |
|---|---|
| `see-through/` | 浅克隆的仓库 |
| `env/` | conda 环境（Python 3.12，torch 2.8.0+cu128，CUDA 可用） |
| `hf/` | 权重缓存（已下约 1.9GB，仍在下载） |
| `ref/whale.jpg`、`ref/whale-v2.png` | 参考图、v2 立绘 |
| `setup.sh`、`setup.log`、`run1.log`、`out/` | 安装脚本与日志、输出目录 |

网络：`gpu-tail` 直连 GitHub 正常，直连 HuggingFace 不通，必须使用 `HF_ENDPOINT=https://hf-mirror.com`。下载速度约 140MB/分钟。

## 5. 续接步骤

1. 查看是否仍在运行与下载进度：

   ```sh
   ssh gpu-tail 'W=/tmp/switchly-whale; pgrep -f inference_psd; du -sm $W/hf; ls $W/out; tail -c 400 $W/run1.log; df -h /tmp | tail -1'
   ```

2. 若进程已退出而权重未齐，重启下载（对 v2 立绘）：

   ```sh
   ssh gpu-tail 'W=/tmp/switchly-whale; export PATH=$HOME/miniconda3/bin:$PATH HF_HOME=$W/hf HF_ENDPOINT=https://hf-mirror.com; source activate $W/env; cd $W/see-through; nohup python inference/scripts/inference_psd.py --srcp $W/ref/whale-v2.png --save_dir $W/out --save_to_psd --tblr_split > $W/run2.log 2>&1 &'
   ```

3. 若 `/tmp/switchly-whale` 已被清除：重新克隆 `shitagaki-lab/see-through`，按其 README 建 Python 3.12 环境与 torch 2.8.0+cu128，再上传立绘（立绘需重新生成，见 §6）。
4. 出 PSD 后：把产物取回本机临时目录，检查边缘与被遮挡部位补全，合并成约 8 个部件（头、前后发、躯干、左右臂、鳍耳、尾鳍/裙摆等），去掉图内白布，横幅单独成层。
5. 用 HTML/Canvas 做小样验证动作设计（待机呼吸、拉开横幅、保持、收起），再到 `tailscale-macos` 做 CALayer 原生小样，记录 CPU 与内存。
6. 小样通过后：回到设计文档裁决 D10 / D11，再按 §8.5 的 S2 实现 `scene` 与 `fs.read`，最后写鲸娘插件。

## 6. 资产与注意事项

- 参考图与立绘 v2 均未入库。立绘 v2 生成提示要点：保持参考图画风与角色特征、正面全身、双臂向两侧拉开、手持纯白无字横幅、头顶留足空白、纯白背景、无贴纸描边。换机后需用户提供参考图并重新生成，或从原机器拷贝。
- 临时文件一律放系统临时目录，任务结束后删除远端 `/tmp/switchly-whale`。
- 会话计数数据源仍是未决项，不得在宿主里写死任何 harness 路径。
- 本文只记录事实与计划；动画流畅度、CPU 占用等数值需小样实测后再写入设计文档。
