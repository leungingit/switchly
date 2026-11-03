# 插件独立预览内部契约

日期：2026-11-03。版本：契约 v1（工具版本 0.1.0）。本文是预览工具内部各部分之间的合同；**可执行的权威检查**是 `plugin-api/preview-*.schema.json`、`Tools/PluginPreview/` 下的测试与 `Tests/PluginPreview/` 下的回归脚本。契约文件变化时，`Tools/PluginPreview/contract-hash.sh --check` 必须同步更新（见第 7 节）。面向使用者的说明见 [使用指南](plugin-preview-guide.md)。

## 1. 边界

预览进程不装配 `PluginHost`、Dock、AX、真实媒体、天气网络或用户目录；每个 worker 只处理一个插件包。所有读取路径必须由调用者明确指定，包使用 `PluginPackageValidator` 校验，fixture 相对场景文件目录解析，拒绝越界、符号链接和非普通文件。每次 `run` 使用独立临时 storage；`dev` 重载时显式保留该会话 storage，重置和关闭时清除。初始授权为场景授予与 manifest 声明的**交集**；`supported` 由运行时实现决定，不接受 fixture 覆盖。正式宿主功能和权限配置不由预览改写。

槽位 `center`、`bottomBar` 反映 Dock 当前接入并会被截图；`topTrailing`、`titleAccessory` 仅作组件预览，不截图。只渲染未截图槽位的插件得到 `unsupported`/`no-capturable-slot`；什么都没渲染得到 `failed`/`empty-render`。`window.focus`、`appleScript` 标记不支持。

预览复用宿主的 Runtime、解码器与渲染代码本身；`Tools/PluginPreview/shared-source-check.sh` 禁止在 Tools/Tests 中另造核心类型，并要求预览 target 编译宿主源文件。

## 2. 场景

`schemaVersion` 为整数 `1`，必填 `id`、`environment`、`target`；未知字段一律拒绝。

- `environment`：`locale`（`en`、`zh-Hans`）、`appearance`（`light`、`dark`）、`glass`、`reduceMotion`、`contentWidthPoints`（>0）。
- `target`：`bundleID`、`appName`，可选 `titleSummary`、`lastActiveAt`。
- `fixtures`：`media`/`weather`/`fs`，相对场景目录的 JSON 文件；缺失表示对应合成能力不可用，不读取真实系统数据。
- `grants`、`settings`、`storageSeed`：权限（与 manifest 取交集）、设置值、初始私有存储。无效设置、权限或路径在启动插件前拒绝。
- `clock`（可选）：`{ startEpochMs ≥ 0, seed: uint32 }`。存在时 JS 的 `Date`、`Math.random`、`setTimeout` 由虚拟时钟接管（`PluginVirtualClock`），Scene 绘制时刻使用同一虚拟时间；时间只在 `advance` 步骤前进。缺省保持实时行为，正式宿主默认不创建虚拟时钟。
- `steps`（可选，≤ 64）：`advance{ms}`（0…86 400 000，需要 `clock`）、`action{id, value?}`（业务动作，直接调用 `onAction`）、`expectText{contains}`、`nativeClick{label, expectAction? | expectDisabled?}`（原生输入，经可访问树 press）。未知类型返回 `unsupported`，字段错误返回 `invalid-scenario`。首个失败即停止，其后记 `skipped`；失败不产生截图。

Fixture Schema 为 `preview-media-fixture`、`preview-weather-fixture`、`preview-fs-fixture`；Schema 不替代运行时对字节数、文件类型、路径及 manifest 设置值的校验。媒体快照须包含公开 `NowPlaying` 的全部字段（含与位置和时长一致的 `progress`）。

## 3. 命令、结果与退出码

`run` 和 `dev` 接受插件目录、`--preview-tool <App>`、`--scenario`；`run` 另需 `--out`（必须是空目录，不覆盖），可选 `--json`。JSON 模式 stdout 只输出一个结果对象，诊断在 stderr，且只含固定诊断（不含 fixture、渲染内容或私密路径）。

| 退出码 | `status` | 含义 |
| --- | --- | --- |
| 0 | `passed` | 渲染与步骤通过，产物完整 |
| 1 | `failed` | 插件/场景问题（错误码见使用指南 §7） |
| 2 | — | 参数错误 |
| 3 | `unsupported` | 不支持的能力 |
| 4 | `environment-error` | 环境问题（无 GUI/授权、工具不配套、找不到工具） |

报告 `report.json`：`schemaVersion: 1`、`status`、`scenarioID`、`pluginID`、`pluginVersion`、`generation`、`packageHash`、`artifacts`、`versions`、`environment`、`failure?`、`steps?`。`environment` 含系统版本、架构、语言、外观、`displayScale`、`rendererRevision`、`glass`、`deterministicClock`。`steps` 仅在场景声明步骤时出现，每项为 `{index, type, source, status, detail?}`，`detail` 只用固定码。产物：`report.json`、`preview.png`、`ui-tree.json`（宿主解码器验证后的原始声明式树）、`actions.json`；失败时只有 `report.json`。截图失败不能返回成功；报告和日志不嵌入 fixture 内容、私密路径或图片 base64。

## 4. 版本握手

预览 App 提供 `--version-json`（无 GUI、无网络）：`tool`、`toolVersion`、`protocolVersion`、`scenarioSchemaVersion`、`pluginAPIVersions`、`sdkContractHash`、`rendererRevision`、`architecture`。CLI 在启动预览前核对：`protocolVersion`、`scenarioSchemaVersion` 与 CLI 要求一致，`toolVersion` 主版本一致，`sdkContractHash` 等于 CLI 随包契约文件的哈希，插件 `apiVersion` 在 `pluginAPIVersions` 内。不一致返回 `incompatible-preview-tool`（4，`error.details.mismatches` 列出字段）或 `plugin-api-unsupported`（3）；工具不支持 `--version-json`、超时（5 秒）、输出无效或超过 16 KiB 同样拒绝。worker 握手在执行任何 JS 前再次核对同样的字段。

## 5. worker 帧与生命周期

传输为四字节无符号大端长度加 UTF-8 JSON；每帧上限复用 `PluginPackageValidator.maxPackageBytes`（32 MiB）。空帧、无效 UTF-8/JSON、截断、超限或不支持协议版本均为协议错误；接收端最多缓存一个未完成帧；worker 同一时刻只处理一个变更请求，控制器最多排队一个请求并合并 invalidate。

帧对象：`protocolVersion: 1`、`type`、`generation`、`requestID`、`payload`。请求：`hello`、`load`、`render`、`action`、`advance`（仅场景声明 `clock` 时可用，单次 ≤ 24 小时）、`suspend`、`resume`、`unmount`、`shutdown`、`storageDump`；响应携带同一 generation/requestID；worker 可发 `invalidate` 事件，事件仅属于当前 generation。Runtime 输出仍通过宿主 `PluginRenderOutput.decode` 校验，GUI 以同一解码器解码。worker 以白名单环境启动；stdout 专用于帧，stderr 只输出固定诊断，插件 `console` 与宿主日志默认被抑制。控制器为启动、每次执行和关闭设置 watchdog，超时先终止、必要时强杀并等待回收；错误 generation 的返回、动作和 invalidate 被丢弃。`dev` 重载：新包完整复制并校验后切换 generation；失败保留旧画面并标为 stale；内容与当前世代一致时不产生新世代。关闭时停止 watcher、timer、管道和子进程；向 CLI 发送 `SIGINT`/`SIGTERM`/`SIGHUP` 会转发给预览进程，10 秒后升级为 `SIGKILL`。

## 6. 视觉基线

逻辑身份是「插件 ID + 场景 ID」；包哈希只作溯源。只有 `deterministicClock` 为真且 `glass` 为假的 `passed` 运行可被 `baseline accept`。兼容指纹为：系统主版本、架构、`displayScale`、`rendererRevision`、`toolVersion`、语言、外观；任一不同则 `baseline compare` 拒绝比较（`incompatible-environment`，退出 4）。比较默认零容差，`--tolerance` 必须显式给出并记录。尺寸变化为 `size-changed`，像素差异为 `visual-diff`，并输出 `diff.png`。基线图片与 `baseline.json` 的哈希不一致视为被篡改（`baseline-invalid`）。

## 7. 可执行的冻结点

| 项 | 常量位置 | 校验 |
| --- | --- | --- |
| 契约哈希：`plugin-api/` 下 6 个契约文件 | `PluginPreviewContract.sdkContractHash` | `Tools/PluginPreview/contract-hash.sh --check` |
| 渲染器 revision：12 个共享渲染源文件 | `PluginPreviewContract.rendererRevision` | `Tools/PluginPreview/renderer-revision.sh --check` |
| 共享源码守卫 | — | `Tools/PluginPreview/shared-source-check.sh` |

三者均并入 `make plugin-preview-contract-check`。更改 Schema 或共享渲染源文件后，必须更新常量并重新接受视觉基线。CLI 与预览工具必须同版本发布（`package-toolkit.sh` 校验）。

## 8. 当前限制

旧系统（macOS 12）、原生 Intel 硬件与无图形会话仅验证了逻辑分支，未在对应环境实测；fixture 更新类步骤未实现；滑块、hover、键盘焦点未覆盖。详见 [覆盖矩阵](plugin-preview-coverage.md)。
