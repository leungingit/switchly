# 插件独立预览内部契约草案

日期：2026-11-03。版本：草案 1；此文件用于协调开发，不表示 G0 已放行或接口已发布。完成 T01 的本体关闭验证、样本和预算测试后，由主控冻结；更改需同步 Schema、实现及测试。

## 边界

预览进程不装配 `PluginHost`、Dock、AX、真实媒体、天气网络或用户目录；每个 worker 只处理一个插件包。所有读取路径必须由调用者明确指定，包使用 `PluginPackageValidator` 校验，fixture 相对场景文件目录解析，拒绝越界、符号链接和非普通文件。每次 `run` 使用独立临时 storage；`dev` 重载时显式保留该会话 storage，重置和关闭时清除。初始授权仅为场景授予与 manifest 声明的交集；`supported` 由运行时实现决定，不接受 fixture 覆盖。正式宿主功能和权限配置不由预览改写。

槽位 `center`、`bottomBar` 反映 Dock 当前接入；`topTrailing`、`titleAccessory` 仅作组件预览并显示未接入提示。`window.focus` 和 `appleScript` 标记不支持。原生窗口截图依赖图形会话，屏幕捕获不可用时报告环境错误；ImageRenderer 当前不能正确绘制全部控件，不作为权威截图。

## 场景与结果

场景 schemaVersion 为整数 `1`，必填 `id`、`environment`、`target`；`environment` 包含 `locale`（`en`、`zh-Hans`）、`appearance`（`light`、`dark`）、`glass`、`reduceMotion`、`contentWidthPoints`；`target` 包含 `bundleID`、`appName`，可选 `titleSummary`、`lastActiveAt`。`fixtures` 中的 media、weather、fs 是相对于场景目录的 JSON 文件路径；`grants` 是能力字符串数组；`settings` 是 manifest 设置键到合法值的映射；`storageSeed` 是 JSON 对象。P0 的 `steps` 只接受空数组或省略，非空时明确返回 unsupported，不能忽略。缺失 fixture 表示对应合成能力不可用，不读取真实系统数据。无效设置、权限或路径在启动插件前拒绝。

`run` 和 `dev` 接受插件目录、`--preview-tool`、`--scenario`；`run` 另需 `--out`，可选 `--json`。JSON 模式标准输出只输出一个结果对象，诊断输出标准错误。成功退出 0；参数/契约错误、插件失败、unsupported、环境错误均非零且分开记录。报告 schemaVersion 为 1，至少含 scenarioID、pluginID、包哈希、工具/协议/schema 版本、generation、检查状态与产物相对路径；状态为 `passed`、`failed`、`unsupported` 或 `environment-error`。P0 产物包括 report.json、preview.png、ui-tree.json、actions.json；截图失败不能返回成功。报告和日志不得嵌入 fixture 内容、私密路径或图片 base64。

草案 Schema 分别为 `plugin-api/preview-scenario.schema.json`、`preview-media-fixture.schema.json`、`preview-weather-fixture.schema.json` 与 `preview-fs-fixture.schema.json`，由 CLI 本地包携带。媒体快照须包含公开 `NowPlaying` 的全部字段，包括与位置和时长一致的 `progress`；天气快照的公开 `source` 是 `online`，合成来源另在诊断中标记。Schema 不替代运行时对字节数、文件类型、路径及 manifest 设置值的校验。

## worker 帧与生命周期

传输采用四字节无符号大端长度加 UTF-8 JSON；每帧上限复用 `PluginPackageValidator.maxPackageBytes`（32 MiB），空帧、无效 UTF-8/JSON、截断、超限或不支持协议版本均为协议错误。该上限是现有整包预算而非输出容量承诺；在 G0 期间需用真实三插件输出及溢出样本检查。接收端最多缓存一个未完成帧；worker 同一时刻只处理一个变更请求，控制器最多排队一个请求并合并 invalidate，超出时明确拒绝。不得无界积压。

帧对象字段：`protocolVersion: 1`、`type`、`generation`、`requestID`、`payload`。请求包括 `hello`、`load`、`render`、`action`、`suspend`、`resume`、`unmount`、`shutdown`；响应携带同一 generation/requestID 与 `ok` 或有界错误码；worker 可发 `invalidate` 事件，事件仅属于当前 generation。握手明确工具版本、协议版本、场景版本、插件 API 范围和 SDK 契约哈希；不兼容在执行 JS 前拒绝。

Runtime 仍通过宿主 `PluginRenderOutput.decode` 校验；worker 传递经此解码确认的原始 JSON，GUI 再以同一解码器解码，不能以另一个宽松 UI 模型代替。进程协议输出与日志分流：保留专用输出管道，stderr 只输出固定诊断，默认抑制可能包含 fixture 内容的插件及宿主日志，禁止污染帧。worker 以白名单环境启动。控制器为启动、每次执行和关闭设置 watchdog，超时先终止、必要时强杀并等待回收；错误 generation 的返回、动作和 invalidate 丢弃。新包先完整复制并校验，成功后切换 generation；重载失败保留旧画面并标为 stale，不能用作成功截图。关闭时停止 watcher、timer、管道和子进程。

## 当前不足

以上仅冻结候选方向：fixture 的完整字段、具体错误码和握手哈希构造需以 T03/T05 的实现样本补齐；正式 Schema 与协议测试是权威可执行检查。旧系统、无 GUI 和 Intel 尚未验证；本体关闭场景已在当前环境验证，见任务书 PT-05。
