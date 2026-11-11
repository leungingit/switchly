# 新版 iPod 资产锁定与后台交互验收（2026-11-11）

## PV-D16：来源与锁定

根据用户提交外仓新版资产、更新宿主锁文件并将 PR #27 转待审的授权，仅提交音乐插件六项既有改动，包括 ipod.glb、blank.png、main.js、两份 locales 和行为测试。外仓提交为 c2487864ae70e877ee539291884f4ae6e807fd11，已推送到 feat/scene3d-preview-base。

验证使用该提交的独立干净检出。以 PR #27 的离线 CLI 包准备校验器，运行 npm test 与 npm run build 后，通过现有 update-plugin-lock.py 显式接受 dist-v2/Plugins 制品。宿主锁文件记录完整来源 SHA，新增 blank.png 并更新 GLB、JS 和两份 locales 的 SHA-256；另外两个插件和 manifest 的文件哈希保持一致。prepare-plugins 与 verify-plugin-release 均通过，普通构建没有自动刷新锁文件。

## 真实验证

| 检查 | 实际结果 |
| --- | --- |
| 外仓 npm test | 46 项通过，0 失败 |
| 外仓 npm run build | 默认兼容线与 v2 线各 3 个插件，通过 |
| 宿主 make bootstrap、make build | 新版锁定制品校验与构建通过 |
| make plugin-preview-build | 通过 |
| make test-unit | 732 项，8 跳过，0 失败 |
| make plugin-preview-contract-check | 契约、Renderer 指纹与 33 个共享核心类型守卫通过 |
| 完整后台交互脚本，输入为固定 revision 的干净检出 | 退出 0，SUMMARY background-input passed |
| 后台 2D 视觉基线脚本 | 通过，包含重复图一致、变化检出、玻璃基线拒绝 |
| 四张锁定制品原生截图 | 初始、toggle、love、drag 均 passed，主控实际查看 |

完整后台脚本包含 17 个进程、1305 个观察样本。上屏、目标前台及激活事件均为 0；所有正向、负向、环境错误、增长、SIGTERM 与 iPod 场景均符合预期。拖动轮记录 35 个其他前台变化样本，来源未归因。脚本没有监听键盘、移动全局指针或阻止用户操作，不能把该记录扩大为全系统零变化保证。

关键原始输出摘录如下。

```text
PASS SIGTERM exit=143 samples=91 visible=0 active=0 activations=0 temporary_entries=0 owned_children_reaped=1
PASS 3d-initial samples=82 visible=0 active=0 activations=0 foregroundChanges=0
PASS 3d-click samples=85 visible=0 active=0 activations=0 foregroundChanges=0
PASS 3d-love samples=88 visible=0 active=0 activations=0 foregroundChanges=0
PASS 3d-drag samples=90 visible=0 active=0 activations=0 foregroundChanges=35
SUMMARY background-input passed
```

额外看图使用宿主 .build/Plugins 中已经过锁文件校验的音乐插件，全部通过正式 run --background 入口和合成媒体 fixture。初始图显示暂停图标；toggle 后变为播放图标；love 后显示填充爱心及粉红爱心前景；drag 后模型透视角度改变，曲目与封面可见。没有真实 Music 操作或 Switchly 本体重启。

## 失败轨迹与交付边界

首轮回归早于预览构建完成启动，probe 未产生有效报告，此轮不计入验收。完整构建退出 0 后，重新执行完整脚本成功。Xcode 的既有 CoreSimulator 组件版本诊断仍出现，macOS 构建与测试实际通过，未修改系统组件。

本条解除 PV-D15 的旧资产坐标不兼容阻塞。PR 可按用户授权转待审，平台与保真边界继续保留。当前为 arm64／macOS 27.2 本机验证，macOS 12、Intel、跨 Space、压力、键盘／hover／滑块、玻璃逐像素等价及多时钟确定性尚未验收。

原宿主混合工作区通过独立检出隔离，未覆盖其已有修改或暂存状态。临时检出、离线包、截图和日志在系统临时目录核验后清理；构建输出遵循仓库约定。交付自检覆盖范围、不可变来源、构建／测试、实际看图、文档覆盖关系和临时文件卫生。

## CI 队列用例的同步修正

资产锁定后的云端 JSC 检查中，进程监督用例报 third request unexpectedly queued。该用例以固定 30ms 等待和 120ms worker 延迟推断并发请求已入队，调度延迟会使第三个请求到达时队列已释放。改用有界文件信号让假 worker 保持首个响应未返回，等待实际首个请求被接收及 queuedRequestCount=1 后验证第三个请求必须拒绝，再显式释放 worker。生产监督器未改，容量、顺序、超时与回收断言均保留。

独立监督测试首次与追加三轮各为 7 passed、0 failed；宿主构建和 732 项单元测试复验通过（8 跳过、0 失败）。
