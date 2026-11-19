# 切窗失败诊断与回归

## WF-D01 按失败阶段定位

所有调用公共窗口聚焦服务的入口使用同一条终态日志 `Window focus failed.`。日志记录目标窗口 ID、目标 PID、Switchly PID、实际使用的桌面分支、AX 授权状态、各轮枚举结果、远程查找结果和尝试聚焦的次数。日志中的枚举错误码为系统原始值，授权状态与具体应用的枚举结果可分别对照。新增终态日志不包含窗口标题、文件路径或截图。

| `stage` | 含义 |
| --- | --- |
| `axEnumerationFailed` | 最后一轮 AX 枚举未取得可用结果，且没有尝试提升候选窗口。查看 `initialAX`、`fallbackAX` 中的 `error:<返回码>` 或 `invalidResponse`。 |
| `otherSpaceTargetNotFound` | AX 枚举成功，但列表和远程查找都没有找到其他桌面的精确窗口 ID。 |
| `targetNotFound` | 最新一轮 AX 枚举成功，但在当前桌面路径没有可尝试的窗口。 |
| `frontRequestFailed` | 已找到其他桌面的精确 AX 窗口，首次系统前置请求失败。 |
| `focusVerificationFailed` | 已尝试聚焦，但在现有校验和宽限复查内未确认目标。候选日志可对照实际最前窗口 ID。 |

跨桌面枚举报错且远程查找未命中时，同一行会给出 `stage=axEnumerationFailed` 和 `remoteLookup=miss`。枚举成功的空数组记录为 `windows:0`。`focusAttempts` 统计提交给聚焦步骤的候选次数，单个候选内的重复提升不另计。同桌面路径尝试过候选后仍失败时，第二次枚举的错误也会保留。远程查找后聚焦成功或宽限复查成功时不写失败终态。应用激活阶段发现进程已退出时仍沿用 `applicationNotFound` 诊断。

## 复发现场

1. 保持当前 Switchly 实例运行。需要文件记录时，在「偏好设置 → 通用 → 写入本地日志文件」启用日志，此设置即时生效。
2. 再点一次失败的窗口，并用同一个 Switchly 进程切换一个已知正常的窗口作为对照。
3. 从本机日志读取终态和同一时间、同一窗口 ID 的候选日志。共享日志片段前按项目的隐私约定脱敏。

```sh
rg -F 'Window focus failed.' ~/Library/Logs/Switchly/Switchly.log
```

## 回归

`WindowFocusResolverTests` 使用受控 AX 枚举和窗口操作替身，验证阶段、错误码、跨桌面精确目标限制、重试和晚到成功。运行 `make test-unit`。真实 Dock 点击和跨桌面焦点仍使用 [受控实机用例](../reviews/all-spaces-window-preview.md#d07dock-全量窗口与真实面板验收)。

## WF-D02 验证结果

2026-11-19 在独立临时构建目录验证。Debug 构建通过，新增回归 11 项全部通过，完整单测 952 项、9 项按条件跳过、0 失败，输出 `TEST SUCCEEDED`。测试通过替身触发故障分支，未撤销系统权限来制造故障，也未运行真实跨桌面点击验收。
