# 后台视觉与输入正式接入记录（2026-11-10）

依据用户“推进正式接入”的授权，实施 PV-D14。本记录区分正式入口回归、前轮可行性证据和未完成的兼容性验收。结论：**本机 arm64／macOS 27.2 上，正式 `run --background` 已能完成限定输入与视觉验证，不显示预览窗口、不激活预览进程、不使用用户的全局键鼠。** 工具仍是本地候选，未提交、推送、签名发布或接入真实 Dock／Music 操作。

## BG-I01：实施边界与实现

- `Tools/PluginPreview/UI/PluginPreviewCaptureSurface.swift` 创建 accessory 进程使用的 nonactivating NSPanel。窗口 alpha=1、几何在所选屏幕内，不可成为 key/main、鼠标穿透、无阴影；后台路径从不调用 orderFront／orderBack／makeKey／activate。
- `@ObservedObject PluginPreviewState` 驱动同一共享 `PluginSlotSurface`，动作后刷新同一视图，原生截图直接读取该窗口的 windowNumber。未增加分层拼接、SceneKit 替身截图或新 Renderer。
- 布局、窗口、鼠标方法均在主线程；捕获子进程采用有界异步等待，主 RunLoop 保持运行。helper、捕获进程、窗口与会话临时目录有清理路径。
- `nativeClick` 保留原进程内 AX press；后台通过同一可执行文件的内部 helper 只读直接父进程的窗口／子节点来准备 AX。不读取标签或其他应用，不写焦点，不执行外部 AX 动作。
- `nativeClickAt` 与 `nativeDrag` 使用截图左上角逻辑点，经边界校验、AppKit hitTest、窗口坐标变换后调用真实 `PluginScene3DPointerView` 的 mouseDown／mouseDragged／mouseUp。仅适配 SceneKit，其他视图明确失败。测试中的 iPod 坐标只是场景夹具，正式驱动没有插件 ID 或固定控件位置分支。
- 输入回调之后等待 worker 动作与渲染完成，错误继续向步骤执行器传播；不把回调到达当成业务执行成功。拖动不要求产生业务动作。
- `Scripts/plugin-preview.sh run`（`mise run preview:run`）自动添加 `--background`，使既有“无界面运行”封装实际采用新路径；直接 CLI 仍显式选择后台。

每次运行先捕获真实画面自检，最终再捕获同一表面。PNG 必须可解码、有可见内容且非单色；不能只检查进程退出码或文件非空。准备、输入、捕获前后检查窗口未上屏、未成为 key/main、进程未激活。环境不支持时失败，不回退显示窗口或全局输入。

## BG-I02：正式二进制与隔离回归

命令：

```sh
make plugin-preview-build
bash Tests/PluginPreview/run-background-input-tests.sh
```

实际脚本汇总如下；它只启动当前 Debug 预览 App，不启动 Switchly 本体。独立 `BackgroundInputProbe` 在启动前开始观察，进程退出后结束，只记录目标窗口是否上屏、目标是否前台、应用激活事件及前台是否改变，不读键盘或其他窗口内容。

| 场景 | 实际结果 |
| --- | --- |
| 初始图、Go、原 7 步 Go／禁用 Stop／Mute | passed；worker 树为 last:none／last:go／last:mute，独立解码后画面像素变化 |
| 点击禁用 Stop | 退出 1，element-disabled |
| Go 被要求为禁用 | 退出 1，element-not-disabled |
| 缺失标签 | 退出 1，element-not-found |
| 错误动作断言 | 退出 1，wrong-action-routed |
| 截图坐标越界 | 退出 1，point-out-of-bounds |
| 坐标命中非 SceneKit 视图 | 退出 1，pointer-target-unsupported |
| 控件回调后 worker 抛错 | 退出 1，step-error；后续步骤 skipped，不生成截图 |
| 超大表面 | 退出 4，environment-error／background-surface-unavailable；没有回退上屏 |
| 点击后内容增长 | passed，最终截图高度大于初始图；保持固定屏幕内原点，不因 AppKit 保留顶边而向屏幕外增长 |
| SIGTERM 中断原生输入 | 退出 143，已记录的 1 个直属子进程回收，临时目录空，没有争写失败报告 |
| iPod 初始／toggle／love／drag | 四轮 passed，toggle 后 pause.fill → play.fill；三类输入后的规范化像素均有变化 |

最终轮关键输出：

```text
PASS positive samples=101 visible=0 active=0 activations=0 foregroundChanges=0
PASS worker-error samples=73 visible=0 active=0 activations=0 foregroundChanges=0
PASS oversized samples=9 visible=0 active=0 activations=0 foregroundChanges=0
PASS grow samples=81 visible=0 active=0 activations=0 foregroundChanges=0
PASS SIGTERM exit=143 samples=94 visible=0 active=0 activations=0 temporary_entries=0 owned_children_reaped=1
PASS 3d-click samples=87 visible=0 active=0 activations=0 foregroundChanges=0
PASS 3d-love samples=93 visible=0 active=0 activations=0 foregroundChanges=0
PASS 3d-drag samples=95 visible=0 active=0 activations=0 foregroundChanges=0
SUMMARY background-input passed
```

17 个进程合计 1318 个独立观察样本，上屏、目标前台、激活事件均为 0。16 个普通／负向场景输出的前台变化均为 0；信号轮验证目标未激活，其前台变化计数不单独摘录。外部观察为采样与激活通知，不证明任意短暂系统变化均可被捕获；结构上禁止后台窗口排序与全局输入，内部另有阶段检查。

## BG-I03：真实看图与基线

另外通过同一正式入口运行并实际查看九张图：

1. 2D 简体中文／深色与英文／浅色，7 步后 last:mute 与控件可见；语言字段只证明路径运行，不将夹具固定英文文本当作完整本地化验收。
2. iPod 初始、toggle、love、drag、深色 toggle：完整模型、合成曲目信息和封面可见；toggle 后显示播放图标；love 显示粉红爱心前景；拖动后模型角度明显改变。
3. 用真实 surface(material: glass) 包裹既有 2D 夹具的浅色／深色图：玻璃底层、边界与控件可见。该包装仅在系统临时目录，没有回写插件仓库。

九轮独立观察共 788 样本，上屏／激活／前台变化均为 0，最大观察间隔约 124.47ms。没有监听或阻止用户真实输入，不将此记录扩大为连续打字吞吐、CPU/GPU 压力或任意 Space 行为保证。

另运行 `bash Tests/PluginPreview/run-baseline-tests.sh`，实际输出 `SUMMARY baseline passed`：接受确定性 2D 基线、同场景差异像素 0、改变插件后检出差异、生成 diff、玻璃像素不同且拒绝接受为基线均通过。没有提高容差。前轮 PV-D13 玻璃最大通道残差 7 和多时钟反例仍有效，本轮没有重新宣称玻璃逐像素等价或动画确定性回放。

## BG-I04：定位并修复的失败

- 首次负向回归报告正确失败，原始 App 进程却退出 0。原因是 NSApplication.terminate 直接退出，main 中 app.run 之后的 exit(delegate.exitCode) 没有执行。现在在 applicationWillTerminate 使用已设定的结果码；正式二进制负向 1、环境 4 均实测。
- 首次 SIGTERM 退出 1，报告把正在关闭表面的输入错误记为 step-failed。信号处理已设置 143，但在途步骤又写出失败报告并改成 1。现在终止开始后，步骤、失败出口与报告出口不再写结果；固定为 143，并加入永久回归。
- 场景独立测试脚本缺少 PackageValidator 已依赖的 GLBPreflight 编译源，无法编译。补齐源文件后真实运行通过，没有降低测试要求。
- AppKit 的 setContentSize 保留顶边，内容变高时可能把底边推到屏幕外；改为按固定屏幕内原点更新 frame，增加真实按钮操作后的增长回归，并查看完整增长图。
- 仓库 run 封装没有添加后台参数，且成功后输出中的 `$out` 紧邻中文括号会被当前 Bash 当成未定义变量。补上后台参数并将变量引用改为 `${out}`，真实执行 7 步后整体退出 0。
- 契约守卫发现原工作区共享 Renderer 已变化而记录仍旧。未覆盖用户源码，按当前实际共享源同步 rendererRevision；新增坐标步骤同步 JSON Schema 与 SDK 契约哈希。旧基线需重新接受，CLI 需携带匹配的契约文件。

## BG-I05：构建与交付检查

| 命令 | 真实结果 |
| --- | --- |
| make plugin-preview-build | 退出 0，Plugin preview build wiring complete；App／Worker 编译成功 |
| make build | 退出 0，Build complete；未启动本体 |
| make test-unit | TEST SUCCEEDED；804 项，含 9 跳过，0 失败 |
| bash Tools/PluginPreview/Scenario/run-tests.sh | 默认场景、覆盖项、inspect、启动器／调试模型、场景与 fixture 路径测试通过，包含坐标解析与错误传播 |
| bash Tools/PluginPreview/Worker/Tests/run-tests.sh | PluginPreviewWorker tests passed |
| bash Tools/PluginPreview/Artifacts/run-tests.sh | 产物、哈希与 PNG 测试通过 |
| npm --prefix Plugins/cli test | 67 passed，0 failed |
| make plugin-preview-contract-check | 契约哈希、rendererRevision 一致；33 个共享核心类型各一处定义 |
| Scripts/plugin-preview.sh run（指定既有 native-input 插件与场景、临时 OUT） | 退出 0，7 步全 passed，自动采用后台路径 |
| git diff --check | 退出 0 |

Xcode 仍输出本机 CoreSimulator 组件版本不匹配诊断，macOS 构建与测试实际成功；没有据此更改系统组件。前台工作台 GUI、真实 Dock／Music、Release 工具包和跨系统验收本轮未执行。

契约哈希：`sha256:23e48934daf60d04e7f5029b24b89fe2c3dfba998afc6ee89bd1adc226f73d51`。

渲染器 revision：`sha256:5a628c4a966ef7691528f0a6a6c656f01253335a0cc8439bd64ee2ab830e44c4`。

已保留用户原有 dirty／未跟踪文件和文档迁移；未改真实媒体桥／宿主业务，没有新增依赖或全局事件 API。本轮脚本、候选输出、截图与日志均在系统临时目录，读取核验并摘录证据后清理；永久回归源码留在 Tests/PluginPreview。项目交付清单按范围、实现、验证、文档和卫生检查，兼容性缺口见下节。

## BG-I06：后续与未放行范围

- 已完成：正式后台入口、标签点击、限定 SceneKit 点击／拖动、动作后画面、负向错误与退出码、信号清理、本机无上屏／激活监测。
- 待验证：macOS 12、原生 Intel、其他 macOS、跨 Space、多显示器切换、压力与连续用户输入矩阵；当前系统每次捕获自检不能替代这些验收。
- 未覆盖：键盘、hover、滑块、任意原生 App、自动定位任意控件、真实 Dock 与系统级鼠标键盘；PV-T03 独立 GUI runner 仍有其用途。
- 保真边界：一张原生返回避免工具自行跨调用拼接；没有证明内部 GPU 多时钟原子一致。玻璃与动画不扩大基线接受规则，保持确定时钟且 glass=false 与默认零容差。
- 后续发布：先完成目标兼容性矩阵，再决定分发放行。本轮不提交／推送／发布。
