# 插件独立预览：开发者与 Agent 使用指南

状态：本地候选（工具版本 0.1.0）。本文所有标注为 `quickstart` 与 `agent-loop` 的命令块由 `Tests/PluginPreview/run-guide-check.sh` 从本文原样提取并在最终工具包上执行；其余命令与退出码以 `Tests/PluginPreview/` 下的回归脚本为准。契约见 [插件独立预览契约](plugin-preview-contract.md)，覆盖范围与未验证项见 [覆盖矩阵](plugin-preview-coverage.md)。

## 1. 它能做什么，不能做什么

在 **Switchly 本体未运行** 的情况下，用与本体同一份 Runtime、解码器和渲染代码，预览插件、执行动作、导出截图与报告。

| 能做 | 不能做（仍由本体验证） |
| --- | --- |
| 用合成的媒体/天气/文件数据渲染插件，导出 `report.json`、`preview.png`、`ui-tree.json`、`actions.json` | 真实 Dock 悬停、Accessibility 切窗、跨屏、桌面玻璃背景 |
| 场景步骤：推进虚拟时间、触发动作、断言文本、经可访问树点击控件 | 真实媒体控制、真实网络天气、读取你的真实目录 |
| 固定时钟下的逐像素视觉基线与差异图 | 滑块调节、hover、键盘焦点（尚未覆盖） |

## 2. 前置条件

- macOS 12 或更新；Node.js 18 或更新。
- `run` 需要截图：图形会话 + 系统设置里授予运行预览的终端/应用「屏幕录制」权限。不可用时命令返回环境错误（退出码 4），**不会**伪造通过。
- 不需要 Xcode，不需要联网，不需要 Switchly 本体在运行。

## 3. 取得并安装工具包

工具包是一个 `switchly-plugin-preview-toolkit-<版本>.tar.gz`（含预览 App、CLI 的 npm tarball、`toolkit-manifest.json`、`SHA256SUMS`）。当前为**本地候选**：ad-hoc 签名，未做 Developer ID 签名与公证，也没有发布到 npm。

维护者在 Switchly 仓库生成它：

```sh
make plugin-preview-package          # 产物在 DerivedData/PluginPreviewRelease/toolkit/
```

作者拿到 tar.gz 后：

```sh
shasum -a 256 -c switchly-plugin-preview-toolkit-0.1.0.tar.gz.sha256
tar -xzf switchly-plugin-preview-toolkit-0.1.0.tar.gz
```

CLI 与 App 必须来自**同一个**工具包。版本、协议或契约哈希不一致时，CLI 在启动预览前拒绝并说明哪一项不一致（退出码 4，错误码 `incompatible-preview-tool`）。

## 4. 快速开始

下面的块从零开始：安装 CLI（离线）、创建插件、写入一个渲染到 `center` 槽位的版本、写场景、运行。运行前设置 `KIT` 为解包后的工具包目录。

```bash quickstart
: "${KIT:?请把 KIT 设置为解包后的工具包目录}"
mkdir -p hello-project && cd hello-project
npm init -y >/dev/null
npm install --offline --no-audit --no-fund "$KIT"/switchly-plugin-cli-*.tgz >/dev/null
npx --no-install switchly-plugin create ./hello --id com.example.hello --name Hello --match com.example.app >/dev/null

# create 生成的插件渲染到 titleAccessory（预览不截图），这里改成 center。
cat > hello/main.js <<'JS'
globalThis.__switchlyPlugin = {
  render(ctx) {
    return [{ slot: "center", node: { type: "vstack", spacing: "s", children: [
      { type: "text", value: "Hello preview", style: "title", lines: 1 },
      { type: "button", id: "go", symbol: "play.fill", label: "Go", size: "m", variant: "plain", enabled: true, selected: false }
    ] } }];
  },
  onAction(ctx, id, value) {}
};
JS

cat > scenario.json <<'JSON'
{
  "schemaVersion": 1,
  "id": "hello",
  "environment": { "locale": "en", "appearance": "light", "glass": false, "reduceMotion": true, "contentWidthPoints": 360 },
  "target": { "bundleID": "com.example.app", "appName": "Example" },
  "clock": { "startEpochMs": 1700000000000, "seed": 1 },
  "steps": [
    { "type": "expectText", "contains": "Hello preview" },
    { "type": "nativeClick", "label": "Go", "expectAction": "go" }
  ]
}
JSON

npx --no-install switchly-plugin validate ./hello
npx --no-install switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --scenario scenario.json --out out --json > result.json
node -e 'const r = JSON.parse(require("fs").readFileSync("result.json", "utf8")); if (r.status !== "passed") { console.error(r); process.exit(1); } console.log("status:", r.status, "steps:", r.steps.map((s) => s.status).join(","));'
```

读结果：`out/report.json`（状态、环境指纹、逐步 trace）、`out/preview.png`（截图）、`out/ui-tree.json`（经宿主解码器验证的原始声明式树）、`out/actions.json`（可用动作与启用状态）。**打开 `preview.png` 看一眼**：退出码 0 只说明渲染成功，不说明画面是你想要的。

## 5. 场景文件

场景是开发用的输入，与发布包的 manifest 分离。未知字段会被拒绝（`invalid-scenario`）。

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 整数 `1` |
| `id` | 场景 ID；与插件 ID 一起构成视觉基线的逻辑身份 |
| `environment` | `locale`（`en`/`zh-Hans`）、`appearance`（`light`/`dark`）、`glass`、`reduceMotion`、`contentWidthPoints` |
| `target` | `bundleID`、`appName`，可选 `titleSummary`、`lastActiveAt` |
| `fixtures` | `media`/`weather`/`fs`：相对场景目录的 JSON 文件路径，不得越界或是符号链接；缺省表示该能力不可用，**不会**读取真实系统数据 |
| `grants` | 授予的权限，与 manifest 声明取交集（超出 manifest 的部分被忽略） |
| `settings` / `storageSeed` | manifest 设置键到合法值的映射 / 初始私有存储 |
| `clock` | `{ "startEpochMs", "seed" }`：JS 的 `Date`、`Math.random`、`setTimeout` 与 Scene 绘制时刻都使用虚拟时间，仅在 `advance` 步骤时前进。缺省为实时 |
| `steps` | 最多 64 个，见下表；缺省或空数组表示只渲染一次 |

槽位：`center`、`bottomBar` 与本体 Dock 一致且会被截图；`topTrailing`、`titleAccessory` 本体 Dock 尚未接入，只渲染而**不截图**——只渲染这两个槽位的插件会得到 `unsupported` / `no-capturable-slot`（退出码 3）。

### 步骤

| `type` | 字段 | 作用 | 证据来源 |
| --- | --- | --- | --- |
| `advance` | `ms`（0–86 400 000） | 推进虚拟时钟并触发到期定时器；**需要场景声明 `clock`** | `clock` |
| `action` | `id`、可选 `value` | **业务动作**：直接调用插件 `onAction`。不证明控件可点击 | `business-action` |
| `expectText` | `contains` | 渲染树的任一文本包含该字符串 | `render-output` |
| `nativeClick` | `label`，可选 `expectAction` 或 `expectDisabled: true`（互斥） | **原生输入**：经可访问树按标签 press，并核对动作确实路由到会话；`expectDisabled` 要求控件存在、禁用且没有动作被触发 | `native-input` |

步骤按顺序执行，**首个失败即停止**，其后步骤记为 `skipped`，整体状态 `failed`、错误码 `step-failed`，且不产生截图（不会出现「失败但有一张好看的图」）。每步 trace 只含固定失败码，不回显断言文本或渲染内容。

## 6. 结果与退出码

`--json` 时 stdout **只有一个 JSON 对象**，诊断一律在 stderr。

| 退出码 | `status` | 含义 |
| --- | --- | --- |
| 0 | `passed` | 渲染与全部步骤通过，产物完整 |
| 1 | `failed` | 插件或场景有问题（见下表） |
| 2 | — | 命令行参数错误 |
| 3 | `unsupported` | 使用了尚不支持的能力（槽位未接入、未知步骤类型、插件 API 超出工具支持范围） |
| 4 | `environment-error` | 环境问题：无图形会话/屏幕录制授权、工具与 CLI 不配套、找不到预览工具 |

> 脚本与 Agent 把 4 视为「没跑成」而不是「通过」；GUI 回归脚本在环境不可用时退出 77，CI 按失败处理。

## 7. 错误修复

下表每一行都由 `Tests/PluginPreview/run-failure-modes-tests.sh` 真实验证。

| 现象（`error.code` / `failure.code`） | 原因 | 修复 |
| --- | --- | --- |
| `no-capturable-slot`（3） | 插件只渲染了 `topTrailing`/`titleAccessory` | 渲染到 `center` 或 `bottomBar` |
| `empty-render`（1） | `render` 返回空数组 | 在目标应用匹配时返回至少一个槽位内容 |
| `plugin-script-error`（1） | `render` 抛出异常 | 在插件里修复；用 `console.log` 不会输出到预览（日志被刻意抑制） |
| `invalid-render-output`（1） | 返回的 UI 不符合声明式树契约 | 对照 [API 参考](plugin-api-reference.md) §7 |
| `plugin-timeout`（1） | 渲染超时（如死循环）；worker 已被终止并回收 | 去掉死循环或阻塞逻辑 |
| `invalid-package`（1） | manifest 损坏、入口缺失或超出包限制 | 先运行 `switchly-plugin validate` |
| `invalid-scenario`（1） | 场景含未知字段或非法值 | 对照第 5 节 |
| `invalid-fixture`（1） | fixture 缺失、过大、越界或与插件根目录不匹配 | 检查 `fixtures` 路径与内容 |
| `invalid-grants` / `invalid-settings`（1） | 授权或设置不符合 manifest | 对照 manifest 的 `permissions` 与 `settings` |
| `step-failed`（1） | 某个步骤失败 | 看 `report.json` 的 `steps`，失败项的 `detail` 是固定码（`text-not-found`、`action-unavailable`、`action-disabled`、`action-ambiguous`、`element-not-found`、`element-disabled`、`wrong-action-routed`、`no-action-routed` 等） |
| `unsupported`（3） | 未知步骤类型 | 只使用第 5 节列出的步骤 |
| `plugin-api-unsupported`（3） | 插件 `apiVersion` 超出工具支持范围 | 升级工具包或调整 `apiVersion` |
| `incompatible-preview-tool`（4） | CLI 与 App 不配套 | 使用同一工具包；`error.details.mismatches` 列出不一致项 |
| `environment-unavailable`（4） | 无图形会话或无屏幕录制授权 | 在有 GUI 的会话运行并授权 |
| `output-not-empty`（2） | `--out` 目录非空 | 换一个空目录（CLI 不会覆盖已有产物） |

## 8. 权限降级

- `grants` 与 manifest 的 `permissions` 取交集；场景里多授予的权限被忽略（不会因此失败）。
- 没有提供对应 fixture 的能力表示**不可用**：插件应处理 `ctx.capabilities[...]`.available 为 false 的降级路径。预览永远不会去读取真实媒体、网络或用户目录。
- `window.focus`、`appleScript` 在预览中标记为不支持。

## 9. 视觉基线

只有**确定时钟且非玻璃**的 `passed` 运行才能作为基线（玻璃截图依赖桌面背景，只能当证据）。

```sh
# 接受：显式操作；已存在时必须再加 --replace
switchly-plugin baseline accept out --baseline-dir baselines
# 比较：默认零容差；--tolerance 0-255 必须显式给出并记录在报告里
switchly-plugin baseline compare out2 --baseline-dir baselines --out cmp --json
```

`cmp/compare-report.json` 给出差异像素数、比例、最大通道差与包围盒，`cmp/diff.png` 把变化标红、其余压暗。基线的逻辑身份是「插件 ID + 场景 ID」，包哈希只作溯源字段；系统主版本、架构、显示缩放、渲染器 revision、工具版本、语言或外观不同则**拒绝比较**（退出码 4，`incompatible-environment`，列出不一致字段）。更新基线是显式动作：确认变化符合预期后 `baseline accept ... --replace`。工具不会自动接受基线，也不会通过放宽阈值让检查变绿。

## 10. dev 模式

```sh
switchly-plugin dev ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --scenario scenario.json
```

打开原生预览窗口。保存文件会整包重新校验并换代；失败（如 manifest 损坏）保留旧画面并标为 stale，修好后再次保存即恢复；内容与当前世代完全一致时不产生多余的新一代。窗口隐藏时暂停受控定时器。关闭窗口或向 CLI 发送 `SIGINT`/`SIGTERM` 会终止预览 App 与 worker，不留孤儿进程。

## 11. Agent 使用约定

1. 始终使用 `--json`，只解析 stdout 的**单个** JSON 对象；不要解析 stderr（只有固定诊断）。
2. 以退出码分流：`0` 成功；`1` 去读 `error.code` 或 `report.json` 的 `failure.code` 与 `steps`，修改插件或场景后重跑；`3` 是能力边界，不要重试；`4` 是环境问题，停止并报告，**不要把它当成通过**。
3. 每次运行用**新的空** `--out` 目录。
4. 退出码 0 之后仍要读 `preview.png` 判断画面是否符合预期；断言文本只能证明「有这段文字」。
5. 区分证据：`action` 步骤是业务动作，`nativeClick` 才经过控件与可访问标签；两者都不能替代本体里的真实 Dock 验证。

下面的循环块同样被原样执行：失败时把 `step-failed` 的失败步骤找出来，演示「运行 → 解析 → 判断 → 修复 → 重跑」。运行前设置 `KIT`，并在 `quickstart` 之后的同一目录执行。

```bash agent-loop
: "${KIT:?请把 KIT 设置为解包后的工具包目录}"
cd hello-project

run_preview() { # 输出目录名
  npx --no-install switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" \
    --scenario scenario.json --out "$1" --json 2>/dev/null
}

# 故意让断言失败：期望一段不存在的文字。
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync("scenario.json", "utf8")); s.steps[0].contains = "Goodbye"; fs.writeFileSync("broken.json", JSON.stringify(s));'
# 注意：在 set -e 下，$(...) 失败会让脚本立刻退出，必须用 && / || 捕获退出码。
result=$(npx --no-install switchly-plugin run ./hello --preview-tool "$KIT/SwitchlyPluginPreview.app" --scenario broken.json --out agent-fail --json 2>/dev/null) && code=0 || code=$?
[ "$code" -eq 1 ] || { echo "期望退出码 1，实际 $code"; exit 1; }
failed_step=$(printf '%s' "$result" | node -e 'const r = JSON.parse(require("fs").readFileSync(0, "utf8")); const f = r.steps.find((s) => s.status === "failed"); console.log(r.failure.code + " " + f.index + " " + f.detail);')
[ "$failed_step" = "step-failed 0 text-not-found" ] || { echo "意外的失败信息：$failed_step"; exit 1; }
echo "诊断：$failed_step"

# 修复（改回正确的断言）后重跑，必须通过。
run_preview agent-pass >/dev/null && code=0 || code=$?
[ "$code" -eq 0 ] || { echo "修复后期望退出码 0，实际 $code"; exit 1; }
echo "修复后通过"
```

## 12. 已知限制

- 工具包是本地候选：未做 Developer ID 签名与公证，未发布 npm；通过浏览器下载的副本会被 Gatekeeper 隔离。
- 已实测架构：arm64 原生与 x86_64（Apple Silicon 上经 Rosetta）；原生 Intel 硬件与 macOS 12 未验证。
- 未覆盖：滑块调节、hover、键盘焦点；窗口隐藏/最小化触发的 `suspend`/`resume` 自动化；fixture 更新类步骤。
- GUI 回归需要有屏幕录制授权的 runner；GitHub 托管 runner 默认没有，见 `.github/workflows/ci.yml` 的 `preview-gui`。
