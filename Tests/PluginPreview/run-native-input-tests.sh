#!/bin/bash
# T15 原生输入回归：经可访问树 press 真实预览窗口里的控件，并核对动作路由与禁用状态。
# 前置：make plugin-preview-build；需要图形会话与屏幕录制授权（截图）。
# 退出码：0 通过；1 失败；77 环境不可用（不是通过，也不是缺陷，需在有 GUI 的环境重跑）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app"
CLI="$ROOT/packages/plugin-cli/bin/switchly-plugin.js"
FIXTURE="$ROOT/Tests/PluginPreview/Fixtures/native-input"
[ -d "$APP" ] || { echo "SKIP: 预览 App 未构建（先运行 make plugin-preview-build）" >&2; exit 77; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-native-input.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

# 运行场景并打印 "<status> <逐步状态:详情>"；CLI 退出码 4 表示环境错误。
run_case() {
  local name="$1" scenario="$2" code out
  out="$(node "$CLI" run "$FIXTURE/plugin" --preview-tool "$APP" --scenario "$scenario" --out "$WORK/out-$name" --json 2>/dev/null)"
  code=$?
  if [ "$code" -eq 4 ]; then echo "SKIP: 预览环境不可用（无图形会话或无屏幕录制授权）" >&2; exit 77; fi
  printf '%s' "$out" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
print(r["status"], ",".join("%s:%s" % (s["status"], s.get("detail", "-")) for s in r.get("steps", [])))'
}

expect() {
  local name="$1" scenario="$2" want="$3" got
  got="$(run_case "$name" "$scenario")"
  if [ "$got" = "$want" ]; then echo "PASS $name"; else echo "FAIL $name: want [$want] got [$got]"; failures=$((failures + 1)); fi
}

# 负向场景：用同一夹具与时钟，仅替换步骤。
python3 -I - "$FIXTURE/scenario.json" "$WORK" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
work = sys.argv[2]
cases = {
    "disabled-click": [{"type": "nativeClick", "label": "Stop"}],
    "not-disabled": [{"type": "nativeClick", "label": "Go", "expectDisabled": True}],
    "missing": [{"type": "nativeClick", "label": "NoSuchControl"}],
    "wrong-action": [{"type": "nativeClick", "label": "Go", "expectAction": "stop"}],
}
for name, steps in cases.items():
    scenario = dict(base, id=name, steps=steps)
    json.dump(scenario, open(f"{work}/{name}.json", "w"))
PY

expect positive "$FIXTURE/scenario.json" "passed passed:-,passed:-,passed:-,passed:-,passed:-,passed:-,passed:-"
expect disabled-click "$WORK/disabled-click.json" "failed failed:element-disabled"
expect not-disabled "$WORK/not-disabled.json" "failed failed:element-not-disabled"
expect missing "$WORK/missing.json" "failed failed:element-not-found"
expect wrong-action "$WORK/wrong-action.json" "failed failed:wrong-action-routed"

[ "$failures" -eq 0 ] && echo "SUMMARY native-input passed" || { echo "SUMMARY native-input failed=$failures"; exit 1; }
