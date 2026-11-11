# MediaRemote Adapter 本地探针实测摘要

> 2026-11-10。仅为独立探针的本机实测，不是宿主实现、兼容性或分发验收。后续方案见 [最小接入设计](../../plugins/mediaremote/music-mediaremote-integration-plan.md)。

## 环境与方法

- macOS 27.2（26B123），Xcode 27.2（27B52）。
- 上游：<https://github.com/ungive/mediaremote-adapter>；revision `0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd`。
- 源码、构建和探针均放在系统临时目录；CMake Release 构建输出 `[100%] Built target MediaRemoteAdapter`，构建脚本对临时 framework 执行 ad-hoc 签名，未使用个人签名身份。
- 通过系统 `/usr/bin/perl` 执行随源码的脚本和构建后的 framework，使用 `stream` 默认增量事件；另用 Apple Events 读取 Music 状态作对照。
- 浏览器为 ego lite，测试页只使用本机音频、封面和 Media Session API。没有发送 Adapter 播放控制命令。
- 采集约 09:56:14～10:03:38（Asia/Singapore），共 93 条 Adapter 事件、577 个有效 Music 对照采样；有效类别均为 `URL track`。

## 局部实测结论

| 编号 | 结果 | 限制 |
| --- | --- | --- |
| M-P01 | 取得 8 个不同歌曲标题的系统封面；已逐图核对 Ancient Ruins of Rauh at Night、Godskin Apostles、象王行（特别版）、Silent Street (Type A) 四个稳定样本，与 Music 界面一致 | 中间快速掠过的歌曲未逐首取得同时刻原生截图 |
| M-P02 | 第一轮约 0.98 秒内点击下一首 4 次，收到 3 个新标题；第二轮约 1.13 秒内点击 3 次，收到 3 个新标题。6 个标题先无图、后补图，延迟约 80～400 毫秒；重建状态没有沿用旧图，两轮最终图均核对正确 | 延迟为 Adapter 新标题事件到图片事件，不是点击总耗时；点击请求数不等于实际切换数 |
| M-P03 | 两次暂停约 57 秒／36 秒；排除边缘后分别 86／54 个对照采样位置不变。恢复后进度继续，封面 SHA-256 不变 | 不是长期稳定性或睡眠恢复验证 |
| M-P04 | Music 继续播放时浏览器抢占，系统返回浏览器标题及蓝色测试图。浏览器暂停后约 27 秒仍保留浏览器会话；关闭测试页后才返回 Music | 证实读取来源冲突，未实测控制误投 |
| M-P05 | Silent Street (Type A) 的稳定 AppleScript 对照返回正确图片：`class=URL track count=1 bytes=993732`，已与界面和系统图片核对 | 不能推导所有 URL track 都正确，也不能把历史“无封面／落后一首”视为当前所有流媒体的必然行为 |

### 快速切歌的封面事件延迟

| 轮次 | 新标题 | 图片相对新标题事件延迟 |
| --- | --- | --- |
| 1 | 日落月胧路难寻 | 226.4 ms |
| 1 | 进入杜比实验室 | 86.1 ms |
| 1 | 象王行（特别版） | 79.9 ms |
| 2 | 昨日梦已远 | 400.0 ms |
| 2 | 仙剑二主题_余情幽梦（水晶版） | 126.1 ms |
| 2 | Silent Street (Type A) | 86.7 ms |

## 证据位置、采集限制与收尾

本次原始证据位于系统临时目录 `switchly-mediaremote-probe.cJzHN9`，包括 `验证报告.md`、`raw.jsonl`、`events.jsonl`、`music.jsonl`、`ui-markers.jsonl`、`summary.json`、`workspace-verification.json`、构建日志、导出封面与原生截图。临时证据可能被系统清理，本文保留可检索的实测摘要；未把个人播放截图及原始会话载荷加入仓库。

初版 AppleScript 对照脚本列表转文本失败，留下 98 条错误记录；09:57:13 修正并重启采集，原错误记录保留。两轮快速切歌、暂停恢复和浏览器实验均在修正后；最初状态和普通切歌另外有原生 AX／截图证据。

探针使用上游自身的事件归并及封面保留逻辑，验证的是该固定版本 Adapter 的输出，不等于直接私有 API 的全部行为。

测试前后 `git status` 与 `git diff --binary` 比较一致，`git diff --check` 无输出。原有正式实现未修改；没有提交、推送或发布。测试浏览器页面已关闭，采集器、Adapter 和本地 HTTP 服务已停止。Music 恢复原歌曲、暂停、位置约 0.208 秒（UI 0:00）、原音量和歌词界面；未清理播放动作产生的系统历史／自动队列变化。下载源码、临时构建与音频夹具已清理，交付证据保留在系统临时目录。

尚未验证：正式宿主集成、其他播放器、macOS 12、Intel 真机、网络中断、睡眠唤醒、长时间运行、发行包签名与公证。没有修改正式代码，因此本轮没有运行宿主构建与单元测试。
