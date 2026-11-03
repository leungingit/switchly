#!/bin/bash
# 性能基线测量（T12/T21）：只记录实测值，不设阈值，不是验收门禁。
# 在解包后的工具包上测量：run 端到端耗时、dev 重载延迟、dev 静止时的 CPU/内存、退出清理耗时。
# 用法：measure-baseline.sh <工具包.tar.gz>   需要图形会话与屏幕录制授权；环境不可用时退出 77。
set -uo pipefail
[ $# -eq 1 ] && [ -f "$1" ] || { echo "用法：$0 <工具包.tar.gz>" >&2; exit 2; }
TARBALL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SELF_DIR/Fixtures/native-input"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-measure.XXXXXX")"
DEV_PID=""
trap '[ -n "$DEV_PID" ] && kill -INT "$DEV_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/kit"
tar -xzf "$TARBALL" -C "$WORK/kit"
KIT="$(find "$WORK/kit" -maxdepth 1 -mindepth 1 -type d | head -1)"
APP="$KIT/SwitchlyPluginPreview.app"
CLI="$WORK/cli"; mkdir -p "$CLI"
(cd "$CLI" && npm init -y >/dev/null 2>&1 && npm install --offline --no-audit --no-fund "$KIT"/switchly-plugin-cli-*.tgz >/dev/null 2>&1)
BIN="$CLI/node_modules/.bin/switchly-plugin"
cp -R "$FIXTURE/plugin" "$WORK/plugin"
python3 -I - "$FIXTURE/scenario.json" "$WORK/scenario.json" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
json.dump(dict(base, id="measure", steps=[]), open(sys.argv[2], "w"))
PY
now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

echo "机器：$(sysctl -n machdep.cpu.brand_string 2>/dev/null)，$(sw_vers -productName) $(sw_vers -productVersion)，$(sysctl -n hw.memsize | awk '{printf "%.0f GiB", $1/1073741824}')"
echo "工具包：$(basename "$TARBALL")"

# 1. run 端到端（CLI → App → worker → 截图 → 退出），5 次
times=()
for i in 1 2 3 4 5; do
  start=$(now_ms)
  "$BIN" run "$WORK/plugin" --preview-tool "$APP" --scenario "$WORK/scenario.json" --out "$WORK/run$i" --json >/dev/null 2>&1; code=$?
  [ "$code" -eq 4 ] && { echo "SKIP: 预览环境不可用" >&2; exit 77; }
  [ "$code" -eq 0 ] || { echo "run 第 $i 次失败（退出 $code）" >&2; exit 1; }
  times+=($(( $(now_ms) - start )))
done
python3 -I - "${times[@]}" <<'PY'
import statistics, sys
t = sorted(int(x) for x in sys.argv[1:])
print("run 端到端 (n=%d)：首次 %d ms；最小 %d / 中位 %d / 最大 %d ms" % (len(t), int(sys.argv[1]), t[0], statistics.median(t), t[-1]))
PY

# 2. dev：重载延迟、静止资源、退出清理
LOG="$WORK/dev.err"
"$BIN" dev "$WORK/plugin" --preview-tool "$APP" --scenario "$WORK/scenario.json" >"$WORK/dev.out" 2>"$LOG" &
DEV_PID=$!
wait_ready() { # 期望的就绪次数，超时 0.05s 单位
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(grep -c 'preview generation ready' "$LOG" 2>/dev/null || true)" -ge "$1" ] && return 0
    kill -0 "$DEV_PID" 2>/dev/null || return 1
    sleep 0.05; i=$((i + 1))
  done; return 1
}
wait_ready 1 600 || { echo "dev 未就绪" >&2; exit 1; }
reloads=()
for n in 2 3 4 5 6; do
  start=$(now_ms); echo "// edit $n" >>"$WORK/plugin/main.js"
  wait_ready "$n" 400 || { echo "重载 $n 未完成" >&2; exit 1; }
  reloads+=($(( $(now_ms) - start )))
done
python3 -I - "${reloads[@]}" <<'PY'
import statistics, sys
t = sorted(int(x) for x in sys.argv[1:])
print("dev 重载延迟（保存→新一代就绪，含整包校验，n=%d）：最小 %d / 中位 %d / 最大 %d ms" % (len(t), t[0], statistics.median(t), t[-1]))
PY

sleep 3   # 让重载后的活动平息，再取静止样本
descendants() { ps -eo pid=,ppid= | python3 -I -c '
import sys
parent = {}
for line in sys.stdin:
    pid, ppid = line.split(); parent.setdefault(int(ppid), []).append(int(pid))
todo = [int(sys.argv[1])]; out = []
while todo:
    for c in parent.get(todo.pop(), []): out.append(c); todo.append(c)
print(" ".join(map(str, out)))' "$1"; }
KIDS="$(descendants "$DEV_PID")"
samples="$WORK/samples.txt"; : >"$samples"
for s in 1 2 3 4 5 6 7 8 9 10; do
  for pid in $KIDS; do ps -o pid=,%cpu=,rss=,comm= -p "$pid" >>"$samples" 2>/dev/null; done
  sleep 1
done
python3 -I - "$samples" <<'PY'
import collections, os, sys
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    parts = line.split(None, 3)
    if len(parts) == 4:
        rows[os.path.basename(parts[3].strip())].append((float(parts[1]), int(parts[2])))
for name, values in sorted(rows.items()):
    cpu = sum(v[0] for v in values) / len(values)
    print("dev 静止 10 s · %-32s 平均 CPU %.1f%%，RSS %.0f MiB（最大 %.0f）" % (name, cpu, sum(v[1] for v in values) / len(values) / 1024, max(v[1] for v in values) / 1024))
PY

start=$(now_ms); kill -INT "$DEV_PID" 2>/dev/null
while kill -0 "$DEV_PID" 2>/dev/null; do sleep 0.05; done
leaked=""; for pid in $KIDS; do kill -0 "$pid" 2>/dev/null && leaked="$leaked $pid"; done
echo "退出清理：SIGINT → CLI 退出 $(( $(now_ms) - start )) ms；残留后代进程：${leaked:-无}"
DEV_PID=""
