# 组合媒体桥正常启动接入与真实 Dock 验收

日期：2026-11-10。对应 [接入设计](../../plugins/mediaremote/music-mediaremote-integration-plan.md) MR-D11。用户授权默认接入、离线打包与本机真实悬停验证；不提交、不推送、不进行发行签名公证。

## 问题与变更

此前 `mise run app → make run → PluginHost.shared` 仍使用 AppleScript，普通 App 也没有 Adapter；候选注入测试成功不意味着日常启动已生效。本轮将共享 Host 改为显式注入 `MediaRemoteAssembly.makeBridge()`，并取消 Host 初始化参数中的隐式 AppleScript 默认值，避免另一个正常构造入口静默绕回旧桥。

主 App 的 `project.yml` 增加唯一的离线打包阶段，在最终 App 签名前运行既有依赖工具的 `embed` 命令。每次校验固定源码并编译双架构框架、脚本、许可证与来源清单；框架使用构建传入的身份签名，没有读取密钥或私有签名配置。编译或框架签名失败时保留原依赖；成功后替换固定资源目录。拒绝 Preview、Worker 与资源路径符号链接。显式 stage 复用 embed，可从已打包宿主创建新的待签名候选，不改输入 App。

## 模块化与解耦审查

| 层 | 责任 | 本轮检查 |
| --- | --- | --- |
| 构建阶段／Python 工具 | 固定源码验证、离线编译、打包与框架签名 | 只挂主 App target；Preview／Worker 不挂此阶段；普通构建不更新清单 |
| MediaRemoteAssembly | 包内路径、真实进程身份、子进程／Session 装配 | 构造不启动采集；可显式传入候选配置 |
| CompositeMediaBridge | 来源配对、整组回退及控制转发 | 不构造真实 OS 依赖，不认识插件 ID；沿用 AppleScript 定向控制、喜欢和资料库 |
| PluginHost／Session | 权限、共享兴趣与采集生命周期 | Host 依赖协议；最后一个消费者关闭后停止采集 |
| Overlay／iPod | 原子展示同批文本和图片 | 本轮未加入来源选择或 Adapter 分支；插件 JS、公开 API、外仓制品与锁文件未作本轮修改 |

结论：本轮接入保持既有模块边界，通过单一装配入口选择系统依赖，通过独立打包入口处理构建责任。没有为 iPod 新建旁路封面逻辑。每次主 App 构建都重新验证、编译 Adapter，会增加少量构建时间；尚未增加产物缓存。

## 真实运行证据

使用正常 `mise run app` 启动的 Debug App，确认可执行路径为仓库 `DerivedData/Build/Products/Debug/Switchly.app`。本轮按用户明确授权使用系统临时目录中的本地程序，移动真实鼠标触发 DockHoverMonitor；没有调用注入式 Panel 验收入口，也没有修改系统权限。桌面工具的后台操作无法触发真实鼠标悬停，因此未把其窗口操作当作悬停通过证据。

- **流媒体封面**：当前歌曲 `Primitive Battle Mode`，AppleScript 确认为 `URL track`。真实 Dock 悬停出现 3D iPod，封面与 Music 的《热烈》原声专辑图一致。采集 Perl 子进程的父进程为正常 Switchly。
- **快速切歌**：连续三次 next，间隔 0.15 秒；过渡截图显示新歌文本加占位图，未沿用《热烈》旧图；最终 `Altus Plateau` 显示 Elden Ring 专辑图，另抓 Music 实际窗口核对一致。上方窗口缩略图可能仍使用旧缓存，因此最终核对使用实际 Music 窗口。截图不是逐帧无错的证明，取消／代际边界仍由回归测试覆盖。
- **浏览器抢占**：Safari 播放仅回环地址提供的本地静音 WAV，系统读数为 `com.apple.WebKit.GPU`／`com.apple.Safari`，标题 `MR Default Browser Fixture`，playing=true。悬停 iPod 保留 Music 的 `Altus Plateau` 文本并撤图，没有使用浏览器图片。
- **浏览器暂停**：系统仍为 Safari、playing=false；iPod 保持回退与占位图。
- **恢复与停止**：关闭测试页并恢复 Music 播放，系统读数回到 `com.apple.Music`，iPod 恢复正确 Elden Ring 封面；移开鼠标后无自有 Perl 残留。
- 测试结束恢复原曲 `Primitive Battle Mode`、暂停、位置 0、音量 57；测试造成的播放历史／队列变化不宣称完全回滚。

证据目录：`$TMPDIR/switchly-mr-default/`。主要截图为 `ipod-streaming.png`、`rapid-transition.png`、`rapid-final.png`、`music-rapid-reference.png`、`browser-takeover.png`、`browser-paused.png`、`browser-recovered.png`；系统来源记录为 `browser-source.json`、`browser-paused-source.json`、`recovered-source.json`。一次手工探针使用相对框架路径失败，改为绝对路径后成功；正常 Assembly 始终传入绝对包路径。

## 构建与回归

- `make generate`、`make build`、`mise run app`：成功，最后再次从 mise 启动正常 Debug App。
- `make test-unit`：`Executed 798 tests, with 9 tests skipped and 0 failures`；`TEST SUCCEEDED`。跳过项包含需显式启用的注入式 live test，本轮悬停证据来自正常运行 App。
- `make mediaremote-adapter-test`：13 项通过；新增 Preview／资源符号链接拒绝、构建及框架签名失败保留旧依赖、已打包 App 的 stage 替换保护。
- `sh Tools/PluginPreview/Worker/Tests/run-tests.sh`：`PluginPreviewWorker tests passed`。
- `Tools/PluginPreview/shared-source-check.sh`：33 个核心类型通过。
- `codesign --verify --deep --strict DerivedData/Build/Products/Debug/Switchly.app`：exit 0；包内 Adapter 架构 `x86_64 arm64`。仅为当前 Debug 签名证据，不代表发行公证完成。
- `git diff --check`：通过。

构建仍有原有 CoreSimulator 版本提示，不影响本轮 macOS 构建测试。`make plugin-preview-contract-check` 仍失败：API hash 匹配，渲染器常量 `2a93d551…` 与实际 `5a628c4a…` 不符，与前轮记录相同。本轮没有修改哈希覆盖的渲染器源码或刷新基线常量，不把该项记为通过。

macOS 12／Intel 真机、真实系统睡眠、完整主题视觉基线及正式发行签名公证继续未验，MR-T05／T06 的整体门禁不能无条件标为完成。本轮仅把默认启动与本机真实悬停接入项从待验改为已验。

## 交付自检签署

按项目 `AGENTS.md` §8 及本机 `delivery-checklist.md` 核对：本轮仅修改装配入口、依赖打包工具／回归、工程真源及相关文档；保留既有脏工作区，未修改插件外仓、公开 API、锁文件和渲染器。构建、测试、实际截图与来源记录均已核对，未验项如上列明。工程通过 `make generate` 生成。临时验证程序／二进制、WAV／HTML 夹具及无关桌面截图已清理，本地测试服务器停止，测试页关闭；仅留必要截图和日志证据，无本轮临时文件落库。原曲暂停／位置／音量已恢复。未提交、推送或公证。
