# 活动追踪连续实机验收窗口

本工具只创建 A／B 两个独立原生测试应用，各显示本次测试文字。它不采集活动、不抓取图片、不修改 Switchly 设置或系统权限；实际记录和采样必须由正式 Switchly 完成。它与使用内存合成数据的 `SwitchlyActivityProbe` 分开，不能单凭工具的状态宣称正式采集通过。

## 准备

所有生成的应用、控制文件和状态放系统临时任务目录，不写入仓库。先完成正式 App 的构建／测试，验收期间固定其路径、PID 与签名，不重签正在运行的副本。

```sh
activity_acceptance_dir=$(mktemp -d "${TMPDIR:-/tmp/}switchly-activity-acceptance-XXXXXX")
swiftc -O Tools/ActivityTrackingAcceptance/Fixture.swift -o "$activity_acceptance_dir/Fixture"
python3 - "$activity_acceptance_dir" <<'PY'
from pathlib import Path
import json, plistlib, shutil, sys
root = Path(sys.argv[1])
for letter in ("A", "B"):
    contents = root / f"Cycle{letter}.app/Contents"
    (contents / "MacOS").mkdir(parents=True)
    shutil.copy2(root / "Fixture", contents / "MacOS/Fixture")
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": f"com.switchly.acceptance.cycle{letter.lower()}",
        "CFBundleName": f"活动连续验收 {letter}",
        "CFBundleExecutable": "Fixture",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
    }))
    (root / f"control-{letter}.json").write_text(json.dumps({"phase": "initial", "mode": "idle"}))
PY
open -g "$activity_acceptance_dir/CycleA.app"
open -g "$activity_acceptance_dir/CycleB.app"
```

正式应用仍需由本轮明确授权开启记录／截图，并仅允许这两个测试 bundle ID。修改前保存原活动设置，结束后还原；不清除既有历史，不修改其他插件授权。录屏撤销与恢复通过原生系统设置完成，身份验证交给用户，不读取密码或 TCC 数据库。

## 控制与边界

指令文件分别为应用目录旁的 `control-A.json`／`control-B.json`。每次指令使用新的 `phase`，例如：

```sh
python3 - "$activity_acceptance_dir" B restored hold 45 <<'PY'
from pathlib import Path
import json, sys
root, letter, phase, mode, seconds = sys.argv[1:]
(Path(root) / f"control-{letter}.json").write_text(json.dumps({
    "phase": phase, "mode": mode, "seconds": int(seconds),
}))
PY
```

- `hold`：本应用请求前台，以实际会话前台应用身份连续保持指定秒数；默认 45 秒，范围 30～120 秒。打断后重新计连续时间。每阶段最多 20 次前台请求、两次请求至少间隔 3 秒，总时长最多 150 秒，不能无限争抢前台。
- `idle`：停止前台请求。切换应用前先给另一个窗口发送新阶段的 `idle` 指令，避免两个测试应用相互争抢。
- 窗口默认放到最后一块显示器的可见区域；多屏仍共享会话前台应用，不能把可见但不在前台的时间计入停留。
- “停止自动前台”按钮立即停止本阶段请求；只有收到新 `phase` 才会恢复。停止或超时不等于达成连续停留目标。
- `status-A.json`／`status-B.json` 保存当前阶段状态；`trace-A.jsonl`／`trace-B.jsonl` 每秒记录前台布尔值、连续秒数、系统输入空闲秒数、单调时间与墙钟，不记录其他应用身份、窗口标题、输入内容或像素。退出工具后停止记录。

## 验收判定

1. **撤权阻断**：确认正式进程确实识别录屏缺失；满足连续前台至少 30 秒且系统空闲小于 300 秒，并在正式活动库确认同一测试区间增长，截图索引没有新条目。不能只凭图片数不变就判通过。
2. **恢复采样**：恢复录屏，按完整路径启动正式副本；让此前未成功采样的测试应用保持至少 30 秒，确认正式索引新增图片，核对 `sessionID`、时间、尺寸和真实内容。
3. **跨会话冷却**：成功采样后保持正式 App 同一 PID，切换到 A 再回到 B。确认 B 新 `sessionID` 已满足停留条件但 600 秒内没有第二张图。
4. **真实时间边界**：以首张 `capturedAt` 为观察锚点，不修改系统时钟、不注入虚拟时间、不缩短生产常量。接近 10 分钟时让 B 连续前台 90 秒，跨过边界；记录边界前截图数与边界后的新图，并核对两张 `capturedAt` 间隔至少 600 秒。

以上均需同时核对正式存储、进程、权限和本工具轨迹。重启正式 App 会重建当前驻内存冷却表，不能把重启前后的图片用于证明同一服务生命周期的冷却。任务结束退出两个测试应用，还原活动设置与系统权限，先保留经过检查的正式证据，再删除本次临时目录。

当前工具在 arm64／macOS 27.2 编译和实测；不代表旧系统、Intel、睡眠或多用户会话验收通过。
