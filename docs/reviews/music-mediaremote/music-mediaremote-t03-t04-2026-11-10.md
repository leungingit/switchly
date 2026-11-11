# MR-T03／MR-T04 实施与验证记录

> 2026-11-10。范围：候选组合媒体桥、内部原子展示、共享读取兴趣、图片解码预算。默认媒体桥仍为 AppleScript；未打包 Adapter，不提交、不推送。契约见[接入设计](../../plugins/mediaremote/music-mediaremote-integration-plan.md)。本记录 M-I05～M-I08 接续 [T01／T02 记录](music-mediaremote-implementation-2026-11-10.md)。

## M-I05：组合读取，定向控制及资料库转发

`CompositeMediaBridge` 同时实现 `MediaReadProviding`、`MediaBridging` 和 `MusicLibraryPlaying`，复用注入的 AppleScript 队列、授权和播放状态协调。构造时可显式传入固定的 `MediaRemoteLaunchConfiguration`；没有默认安装路径，创建桥本身不启动采集。

读取先取得 Music 采样，再冻结系统快照，再取 Music 采样；检查精确来源、PID 与启动身份、来源内标识、完整元数据、时长和状态机歧义。配对通过后使用系统歌曲组，喜欢能力与状态来自已配对的 Music，播放图标使用 AppleScript 的实际／协调结果。首次不可靠配对、来源被浏览器占用、Music 身份变化或自动化不可读时，整组回退 AppleScript。暂停的浏览器仍被拒绝，不冒充 Music。

next／previous 和资料库 play 发出前撤销旧图资格。所有命令、喜欢、选曲、指定歌曲播放、暂停和 currentTrack 均转发到 AppleScript，不向 Adapter 发送控制命令。原有 `URL track` 图片拒绝策略不变。配对仍是保守一致性检查，不是权威跨来源 ID 映射。

## M-I06：冻结读取与原子展示

`MediaReadContext` 只在宿主内部流转，持有固定 NowPlaying、已解码图片、内容 token 及有效性检查。Runtime 的 render 使用按调用封闭的 Promise 读取同一快照；不能从 runtime 全局可变 pin 读到其他批次。控制动作不使用 render pin；只授权 control 的 Runtime 连传给内部工厂的参数也不包含歌曲。读取失败仍表现为 rejected Promise，避免错误路径绕回分离读取。

`DockPluginOverlayModel` 在所有 runtime 渲染和图片准备完成后，检查 generation、renderRevision 和媒体有效性，将 slots、动作归属、图片及 token 写入一个 `DisplayState`。主线程只发布一次；没有 artwork 节点或没有图片时明确清空图片。换歌／来源事件先撤旧封面，图片补到后请求整组渲染。2D、Scene 与 scene3d 仍读取相同的 artwork／token。

渲染同时最多一个在途批次和一个待处理请求；过期批次最多追加一次即时重读，后续依赖新事件或正常刷新，防止持续失败造成无限脚本重试。Host 对每次采样及提交检查当前授权；reload／unmount 撤销持有的兴趣。Preview Worker 的 JSON render 也冻结每批 fixture 元数据，动作仍访问实时 fixture，Worker target 不编译真实 Adapter 采集组件。

## M-I07：共享兴趣、生命周期及图片预算

一个组合桥拥有一个 `MediaRemoteSession` 和一条流。已授权可见叠层取得幂等兴趣句柄；首个兴趣启动，最后一个取消停止，单个消费者离开不影响其他消费者。Host reload、unmount、销毁及叠层 stop／销毁释放句柄；叠层 deinit 不再卸载整个共享 Host，避免影响其他消费者；授权变化时清理不再合法的兴趣。失效通知对每位消费者最多排队一次主线程回调。

睡眠撤销连接与图像，唤醒在仍有兴趣时重建一次。目标启动／退出通知核对实际进程身份，变更后重建连接；进度读取使用单调时钟，不人为制造歌曲代际。失败周期内增加消费者不会重启。

`MediaArtworkDecoder` 在后台检查压缩字节、ImageIO 类型／帧数及尺寸，只允许单帧 PNG、JPEG、HEIC、HEIF。压缩数据不超过 8 MiB，源最长边 4096，源像素不超过 4096²。复用 `ThumbnailService.fittedPixelSize`，缩略图最长边 512；最终强制绘制为 sRGB RGBA8，按实际 bytesPerRow × height 检查不超过 1 MiB，不将任意压缩数据直接交给主线程 NSImage 懒解码。

会话只缓存当前封面、一个在途解码和一个最新待解码候选；候选替换不无限排队。来源／歌曲／连接失效后，迟到解码即使成功也不能恢复旧图。图片只在内存，不下载 URL、不写封面磁盘缓存、不传给 JS。

## M-I08：验证与边界

测试覆盖组合配对／回退、浏览器暂停抢占、无授权、夹取期间换歌、定向控制、喜欢／资料库、共享兴趣、失败周期不重启、睡眠唤醒、旧连接与迟到解码、render pin、control-only 防泄露、错误 Promise、原子发布、清空旧图及图片字节／像素／内存／颜色保真。

首轮测试暴露 NSImage 内部表示断言不成立；解码器随后改为实际 RGBA8 绘制并以 NSBitmapImageRep 承载。构建捕获过非可选构造被错误用于 guard let 的问题，已修正。颜色测试按源图与结果共同转换到 sRGB 比较，避免将设备 RGB 数值当成固定 sRGB 数值。

最终实际验证结果：

| 命令／检查 | 结果 |
| --- | --- |
| `make generate` | 成功，主 App 新增源码与测试引用；Worker 仅新增共享内部快照类型 |
| `make build` | 退出 0，`Build complete!`，无本轮 Swift 编译警告 |
| `make test-unit` | `Executed 793 tests, with 8 tests skipped and 0 failures`；`TEST SUCCEEDED`；相对 T01／T02 新增 22 项 |
| `sh Tools/PluginPreview/Worker/Tests/run-tests.sh` | `PluginPreviewWorker tests passed`，无真实 Adapter 来源 |
| `make mediaremote-adapter-test` | `Ran 6 tests`，`OK` |
| `Tools/PluginPreview/shared-source-check.sh` | 33 个核心类型共享源码守卫通过 |
| 浅／深色 fixture 看图 | 实际查看 `atomic-light.png` 与 `atomic-dark.png`：灰色已解码封面、文字布局与主题正确；仅夹具验证 |
| 默认来源与 App 包 | `PluginHost` 参数仍为 `MusicAppleScriptBridge()`；Debug 包中无 MediaRemoteAdapter 制品 |
| `git diff --check`、范围及链接 | 无差异空白错误；任务范围外既有 tracked diff 保持一致；本轮 3 个台账的 9 个相对链接有效 |

Xcode 仍输出既有 CoreSimulator 版本不匹配提示，macOS 构建／测试成功。没有修改系统环境；8 个跳过均为既有项目测试。日志与两张共享视图的浅／深色 fixture 图保留在系统临时目录 `switchly-mr-t03-t04`，可能被系统清理；无原始歌曲或会话数据。

额外检查发现 `make plugin-preview-contract-check` 的 renderer revision 与已有脏工作区不一致：常量 `sha256:2a93d551a7b590d2dfdcb4ffdad35dec2ff37305bb1c821fb777de096240242f`，实际 `sha256:5a628c4a966ef7691528f0a6a6c656f01253335a0cc8439bd64ee2ab830e44c4`。本轮没有修改该哈希脚本覆盖的视图文件，未刷新常量或接受视觉基线绕过门禁。Worker 独立测试脚本补齐当前工程已引用的 scene3d 描述、surface 契约和 GLB 预检源码后，可编译共享 Runtime 与新增内部快照类型。

## 自检与后续

按项目 AGENTS.md §8 与通用交付清单核对：本轮文件范围外的既有 tracked diff 与开始时逐段比较一致；未改插件外仓、公开 API 或插件锁。原始 T01／T02 记录保留，新状态以本记录为准。

MR-T03／T04 完成组件实施及测试，MR-T05／T06 仍待执行：真实 Dock 快速切歌／暂停恢复／浏览器抢占、2D／3D 同图、真实隐藏／撤权／睡眠唤醒、macOS 12／Intel、发行包路径与嵌套签名／公证。浅／深色 fixture 图只证明共享视图渲染，不代表真实 Music 封面与 Dock 已验收；因此 MR-G01～G04 仍不能宣称整体通过。

后续状态更新：上文「T05／T06 仍待执行」被 [本机验证与架构审查](music-mediaremote-t05-t06-architecture-2026-11-10.md) 的分项状态取代；共享 VM 所有权、锁内计算及真实系统装配职责在该轮作了修正，原始测试证据保留。
