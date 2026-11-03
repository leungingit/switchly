#!/bin/bash
# T16 视觉基线端到端回归：真实预览 → baseline accept → 同场景再次运行应逐像素一致 →
# 改动插件后 compare 必须检出并给出差异图；玻璃场景不得被接受为基线。
# 前置：make plugin-preview-build；需要图形会话与屏幕录制授权。退出码：0 通过；1 失败；77 环境不可用。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app"
FIXTURE="$ROOT/Tests/PluginPreview/Fixtures/native-input"
[ -d "$APP" ] || { echo "SKIP: 预览 App 未构建（先运行 make plugin-preview-build）" >&2; exit 77; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-baseline.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0
cli() { node "$ROOT/packages/plugin-cli/bin/switchly-plugin.js" "$@"; }

# 用 steps 为空的确定时钟场景：夹具场景含原生点击步骤，这里只取其环境与时钟。
python3 -I - "$FIXTURE/scenario.json" "$WORK" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
work = sys.argv[2]
json.dump(dict(base, id="baseline-plain", steps=[]), open(f"{work}/plain.json", "w"))
json.dump(dict(base, id="baseline-glass", steps=[], environment=dict(base["environment"], glass=True)), open(f"{work}/glass.json", "w"))
PY
cp -R "$FIXTURE/plugin" "$WORK/plugin"

run_preview() { # name scenario
  cli run "$WORK/plugin" --preview-tool "$APP" --scenario "$2" --out "$WORK/$1" --json >"$WORK/$1.json" 2>/dev/null
  local code=$?
  if [ "$code" -eq 4 ]; then echo "SKIP: 预览环境不可用（无图形会话或无屏幕录制授权）" >&2; exit 77; fi
  return "$code"
}
check() { # 描述 期望退出码 实际退出码
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: want exit $2 got $3"; failures=$((failures + 1)); fi
}

run_preview r1 "$WORK/plain.json"; check "首次运行成功" 0 $?
cli baseline accept "$WORK/r1" --baseline-dir "$WORK/baselines" --json >/dev/null 2>&1; check "接受基线" 0 $?

run_preview r2 "$WORK/plain.json"
cli baseline compare "$WORK/r2" --baseline-dir "$WORK/baselines" --out "$WORK/c2" --json >"$WORK/c2.json" 2>/dev/null; check "同场景重复运行逐像素一致" 0 $?
python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["diff"]["pixels"] == 0 else 1)' "$WORK/c2.json"; check "差异像素为 0" 0 $?

sed -i '' 's/"last:" + last/"seen:" + last/' "$WORK/plugin/main.js"
run_preview r3 "$WORK/plain.json"
cli baseline compare "$WORK/r3" --baseline-dir "$WORK/baselines" --out "$WORK/c3" --json >"$WORK/c3.json" 2>/dev/null; check "改动插件后被检出（退出 1）" 1 $?
python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
ok = r["failure"]["code"] in ("visual-diff", "size-changed") and r["packageChanged"] is True
sys.exit(0 if ok else 1)' "$WORK/c3.json"; check "报告标明视觉差异且包哈希已变" 0 $?
[ -s "$WORK/c3/diff.png" ] || [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["failure"]["code"])' "$WORK/c3.json")" = "size-changed" ]; check "有差异图（或明确的尺寸变化）" 0 $?

run_preview g1 "$WORK/glass.json"
cli baseline accept "$WORK/g1" --baseline-dir "$WORK/baselines-glass" --json >/dev/null 2>&1; check "玻璃截图不能作为基线（退出 1）" 1 $?

[ "$failures" -eq 0 ] && echo "SUMMARY baseline passed" || { echo "SUMMARY baseline failed=$failures"; exit 1; }
