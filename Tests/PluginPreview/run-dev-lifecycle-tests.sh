#!/bin/bash
# T10/T17 dev 生命周期端到端：整包热重载、损坏重载保留旧画面、修复后恢复、SIGINT 后无残留进程。
# 前置：make plugin-preview-build；需要图形会话。退出码：0 通过；1 失败；77 环境不可用。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app"
FIXTURE="$ROOT/Tests/PluginPreview/Fixtures/native-input"
[ -d "$APP" ] || { echo "SKIP: 预览 App 未构建（先运行 make plugin-preview-build）" >&2; exit 77; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-dev-lifecycle.XXXXXX")"
DEV_PID=""
cleanup() {
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then kill -INT "$DEV_PID" 2>/dev/null; fi
  pkill -f "$WORK/plugin" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

cp -R "$FIXTURE/plugin" "$WORK/plugin"
python3 -I - "$FIXTURE/scenario.json" "$WORK/scenario.json" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
json.dump(dict(base, id="dev-lifecycle", steps=[]), open(sys.argv[2], "w"))
PY
LOG="$WORK/dev.err"
node "$ROOT/Plugins/cli/bin/switchly-plugin.js" dev "$WORK/plugin" --preview-tool "$APP" --scenario "$WORK/scenario.json" >"$WORK/dev.out" 2>"$LOG" &
DEV_PID=$!

count() { grep -c "$1" "$LOG" 2>/dev/null || true; }
# 等待日志中某关键字出现至少 N 次；进程提前退出或超时返回 1。
wait_for() { # 关键字 次数 超时(0.2s 单位)
  local i=0
  while [ "$i" -lt "$3" ]; do
    [ "$(count "$1")" -ge "$2" ] && return 0
    kill -0 "$DEV_PID" 2>/dev/null || return 1
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

if ! wait_for "preview generation ready" 1 150; then
  if ! kill -0 "$DEV_PID" 2>/dev/null; then wait "$DEV_PID"; code=$?; [ "$code" -eq 4 ] && { echo "SKIP: 预览环境不可用（无图形会话）" >&2; DEV_PID=""; exit 77; }; fi
  fail "首次加载未就绪"; echo "SUMMARY dev-lifecycle failed=1"; exit 1
fi
pass "首次加载就绪"

echo "// edit" >> "$WORK/plugin/main.js"
wait_for "preview generation ready" 2 100 && pass "保存后整包重载（第 2 代）" || fail "保存后未重载"

cp "$WORK/plugin/manifest.json" "$WORK/manifest.good"
printf '{ broken' > "$WORK/plugin/manifest.json"
wait_for "preview reload failed" 1 100 && pass "损坏的包重载失败被报告" || fail "损坏重载未被报告"
[ "$(count 'preview generation ready')" -eq 2 ] && pass "失败重载没有产生新一代" || fail "失败重载产生了新一代"
kill -0 "$DEV_PID" 2>/dev/null && pass "失败重载后预览进程仍存活（保留旧画面）" || fail "失败重载后进程退出"

# 恢复为与当前世代完全相同的内容：磁盘与已激活包一致，按设计不应产生新一代。
cp "$WORK/manifest.good" "$WORK/plugin/manifest.json"
sleep 3
[ "$(count 'preview generation ready')" -eq 2 ] && pass "恢复为相同内容不产生多余的新一代" || fail "相同内容触发了多余重载"
# 再做一次真实改动，确认损坏之后监听与重载仍然可用。
echo "// edit again" >> "$WORK/plugin/main.js"
wait_for "preview generation ready" 3 100 && pass "损坏之后再次修改可恢复重载（第 3 代）" || fail "损坏之后未恢复重载"

descendants() { # 递归列出 $1 的所有后代 PID
  ps -eo pid=,ppid= | python3 -I -c '
import sys
parent = {}
for line in sys.stdin:
    pid, ppid = line.split()
    parent.setdefault(int(ppid), []).append(int(pid))
todo = [int(sys.argv[1])]; out = []
while todo:
    for child in parent.get(todo.pop(), []):
        out.append(child); todo.append(child)
print(" ".join(map(str, out)))' "$1"
}
CHILDREN="$(descendants "$DEV_PID")"
[ -n "$CHILDREN" ] && pass "dev 进程树含预览 App 与 worker（$(echo $CHILDREN | wc -w | tr -d ' ') 个后代）" || fail "未找到 dev 的后代进程"

kill -INT "$DEV_PID" 2>/dev/null
i=0; while kill -0 "$DEV_PID" 2>/dev/null && [ "$i" -lt 75 ]; do sleep 0.2; i=$((i + 1)); done
if kill -0 "$DEV_PID" 2>/dev/null; then fail "SIGINT 后 15 秒内未退出"; else pass "SIGINT 后退出"; fi
DEV_PID=""
# 有界等待：这次 dev 的所有后代进程必须消失；持续存活才算泄漏。
leaked=""
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  leaked=""
  for pid in $CHILDREN; do kill -0 "$pid" 2>/dev/null && leaked="$leaked $pid"; done
  [ -z "$leaked" ] && break
  sleep 0.2
done
[ -z "$leaked" ] && pass "退出后本次 dev 的预览与 worker 进程全部消失" || fail "退出 5 秒后仍有进程残留：$leaked"

[ "$failures" -eq 0 ] && echo "SUMMARY dev-lifecycle passed" || { echo "SUMMARY dev-lifecycle failed=$failures"; exit 1; }
