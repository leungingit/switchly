# MR-T01／MR-T02 实施与测试记录

> 2026-11-10。用户授权：完成离线依赖、进程封装、来源与歌曲状态机及对应测试；不接入默认媒体桥，不提交、不推送。任务契约见 [接入设计](../../plugins/mediaremote/music-mediaremote-integration-plan.md)。

## M-I01：固定离线依赖

`Vendor/MediaRemoteAdapter/upstream` 保留上游 `0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd` 的 30 个原样文件及 BSD-3-Clause 许可证。来源、归档哈希和逐文件哈希在 `source.json`；构建脚本无网络、更新清单或接受新 revision 的入口。

`Scripts/mediaremote-adapter.py` 用 Python 标准库校验输入，以系统 Xcode clang 构建 framework，不新增 CMake 要求。产物含 framework、固定脚本、许可证及来源清单；输出必须显式指定，拒绝覆盖已有依赖产物。没有调用个人证书签名、公证或修改 App 包。

实际在禁止网络的系统沙箱中执行：

```sh
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  make mediaremote-adapter-build MEDIAREMOTE_OUTPUT="$TMPDIR/<任务目录>/offline-output"
```

实际结果：离线校验 30 个文件通过，离线构建退出 0。`xcrun lipo -archs` 输出 `x86_64 arm64`；`xcrun vtool -show-build` 的两个架构均为 `platform MACOS`、`minos 12.0`、`sdk 27.2`。这仅证明编译产物声明，不等同于 Intel／macOS 12 真机运行。

`make mediaremote-adapter-test`：6 个测试通过，覆盖固定输入、源文件篡改、缺失／额外文件、额外顶层输入、revision 改变及符号链接。测试只修改系统临时目录中的副本。

## M-I02：进程协议与真实管道

新增 `MediaRemoteChildProcess` 协议、Foundation 实现、`MediaRemoteStream` 和增量行解码器，均未装配到默认桥。只允许固定系统 Perl 路径、脚本／framework 参数和 `stream` 命令，不使用 shell 或系统媒体命令。

- 读取单块最多 64 KiB，以同步交接提供背压，追加前检查 12 MiB 单行上限；支持跨分片 UTF-8、多行、截断及格式错误。
- 首次完整事件前收到 diff 失败；合法空完整事件算就绪，不按“没有歌曲变化”重启。启动期限 2 秒。
- stderr 正文不进入事件或日志，一条连接最多一条无正文诊断；失败不自动重启，显式 stop 后新周期才可再启动。
- 退出和取消以连接 UUID 拒绝旧回调；stop 先 SIGTERM，1 秒期限后仅对仍运行的自有子进程升级清理；owner 销毁后清理仍能完成。
- 10 个流测试通过，含真实 `/usr/bin/perl` 临时夹具、带空格参数、stdout／stderr、小事件及时交付和进程退出。夹具不访问真实媒体会话。

首轮全量测试有一个真实管道用例超时：Foundation 的指定长度读取未及时交付小事件。改为 readiness 回调内的有界 POSIX `read` 后，定向和最终全量测试通过；没有通过增大等待或删除检查掩盖问题。

## M-I03：来源与歌曲状态机

`MediaRemoteState` 只生成候选快照；复用既有 `NowPlaying`，不改变公开 JS API、不执行控制或图片解码。19 个测试通过，覆盖：

- Music 精确 Bundle ID、PID 与注入的启动身份；浏览器及其伪装 parent Bundle ID 拒绝，目标退出／PID 复用撤销旧资格。
- 首次完整快照、全量替换、增量合并、显式 null 删除、空会话、缺元数据；连接重建从空状态开始。
- 标识或歌曲元数据变化递增歌曲代际，新歌不继承旧图；控制请求先撤图，旧歌的迟到图片不能解除换歌屏障。
- 图片 null、全量快照无图、Base64 错误与超过 8 MiB 拒绝；进度事件不重复转换已有 Base64 或重新计算图片摘要。
- 同元数据不同来源内 ID 标为歧义；前后 Music 采样检查身份、完整元数据、时长差、当前 token 与已知歧义，配对不可靠时拒绝。
- 暂停冻结、恢复推进、seek 重建锚点和进度钳制；基准时间换算后使用单调时钟，不按每秒轮询脚本推算。

候选快照的 `canLike=false` 只表示尚未配对的内部数据，不向现有插件发布。后续 MR-T03 仍须整组配对／回退，保留用户当前的喜欢和资料库能力。跨来源一致性检查不是权威 ID 映射；无法为缺少身份的上游迟到图片推断真实归属，不能将 token 拒绝机制解释为解决所有上游错配。

## M-I04：最终构建与边界核验

实际执行：

| 检查 | 结果 |
| --- | --- |
| `make generate` | 成功；新增源码／测试由现有 project.yml 目录规则生成工程引用 |
| `make build` | 退出 0，`Build complete!` |
| `make test-unit` | `Executed 771 tests, with 8 tests skipped and 0 failures`；`TEST SUCCEEDED`，其中新增媒体测试 29 个 |
| `make mediaremote-adapter-test` | `Ran 6 tests`，`OK` |
| 禁网沙箱下显式依赖构建 | 退出 0，双架构均声明 macOS 12.0 |
| 默认装配与产物 | `PluginHost` 仍为 `MusicAppleScriptBridge()`；Debug App 内没有 Adapter framework |
| 原有差异保护 | 除本次明确修改的工程／文档外，测试前已有跟踪文件差异逐段比较一致；现有媒体桥、Runtime、Overlay、插件锁未改 |
| `git diff --check` | 无输出 |

Xcode 输出既有 CoreSimulator 版本不一致提示；本次 macOS 构建和测试实际成功，没有修改模拟器安装或系统配置。

日志位于本机系统临时目录 `switchly-mr-t01-t02.BpcujY`，主要文件为 `build-final.log`、`test-unit-final.log`、`mediaremote-tests.log`、`offline-build.log`。临时编译和源码下载产物任务收尾清理；交付所需日志保留，可能被系统清理。没有 UI 或渲染行为改动，本轮不新增界面验收截图。

## 后续与自检

MR-T01／MR-T02 已完成独立组件范围，MR-T03 组合桥及原子渲染、MR-T04 共享兴趣／睡眠唤醒／图片解码预算、MR-T05 真实 Dock 验收、MR-T06 发行兼容验证均未实施。MR-G01／MR-G02 仍未整体通过，不能宣称音乐插件已使用新来源。

按项目 AGENTS.md §8 与通用交付清单核对：无默认桥接、没有新增运行时网络、没有读取凭据或修改权限、没有提交推送；临时夹具不入库，正式依赖与测试按目录归档。普通 build／test 只校验固定依赖，真实 Adapter 进程不会自动启动。

后续状态更新：上文 T03／T04「未实施」状态被 [M-I05～M-I08](music-mediaremote-t03-t04-2026-11-10.md) 取代；T01／T02 的原始证据保持不变。
