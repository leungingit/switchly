#!/bin/bash
# T19 干净环境演练：模拟插件作者拿到「插件仓库 + 工具包」后的完整闭环，期间不接触宿主源码、Xcode 或网络：
#   解包 → 离线安装 CLI → validate → run → 读报告与截图 → 接受基线 → 改动场景后重跑（必须被检出）→ 恢复后重跑（必须通过）。
# 用法：run-clean-room.sh <工具包.tar.gz> <插件仓库目录>
# 插件仓库需含 plugins/、preview/scenarios/ 与 preview/scenario-plugins.json；演练自动选取首个「确定时钟且非玻璃」的场景。
# 需要图形会话与屏幕录制授权。退出码：0 通过；1 失败；77 环境不可用（不是通过）。
set -uo pipefail
[ $# -eq 2 ] && [ -f "$1" ] && [ -d "$2/preview/scenarios" ] || { echo "用法：$0 <工具包.tar.gz> <插件仓库目录>" >&2; exit 2; }
TARBALL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
REPO="$(cd "$2" && pwd)"
HOST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NODE_DIR="$(dirname "$(command -v node)")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-cleanroom.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/kit" "$WORK/home" "$WORK/cache" "$WORK/author"
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1（期望 $2，实际 $3）"; fi; }

# 作者环境里只有插件仓库副本（不含 .git、不含宿主），目录名与路径都与本机工作区无关。
mkdir -p "$WORK/author/plugins-repo"
cp -R "$REPO/plugins" "$REPO/preview" "$WORK/author/plugins-repo/"
AUTHOR="$WORK/author/plugins-repo"

tar -xzf "$TARBALL" -C "$WORK/kit" || { fail "解包失败"; exit 1; }
KIT="$(find "$WORK/kit" -maxdepth 1 -mindepth 1 -type d | head -1)"
APP="$KIT/SwitchlyPluginPreview.app"
CLI_TGZ="$(find "$KIT" -maxdepth 1 -name 'switchly-plugin-cli-*.tgz' | head -1)"
(cd "$WORK/author" && npm init -y >/dev/null 2>&1 && HOME="$WORK/home" npm install --offline --no-audit --no-fund --cache "$WORK/cache" "$CLI_TGZ" >/dev/null 2>&1)
check "离线安装 CLI（无网络、空缓存）" 0 $?
CLI="$WORK/author/node_modules/.bin/switchly-plugin"

CLEAN_ENV=(env -i PATH="$NODE_DIR:/usr/bin:/bin" HOME="$WORK/home" TMPDIR="$WORK" DEVELOPER_DIR=/nonexistent)
SANDBOX=()
command -v sandbox-exec >/dev/null 2>&1 && SANDBOX=(sandbox-exec -p '(version 1)(allow default)(deny network*)')
cli() { (cd "$WORK/author" && "${CLEAN_ENV[@]}" "${SANDBOX[@]}" "$CLI" "$@"); }

# 选取首个确定时钟且非玻璃的场景，并按仓库自己的映射找到插件。
python3 -I - "$AUTHOR" >"$WORK/pick.tsv" <<'PY' || { echo "FAIL 仓库中没有「确定时钟且非玻璃」的场景可供演练"; exit 1; }
import glob, json, os, sys
repo = sys.argv[1]
mapping = json.load(open(os.path.join(repo, "preview", "scenario-plugins.json")))
root = os.path.join(repo, "preview", "scenarios")
for scenario in sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True)):
    rel = os.path.relpath(scenario, root)
    if "fixtures" in rel.split(os.sep):
        continue
    data = json.load(open(scenario))
    plugin = mapping.get(rel.split(os.sep)[0])
    if plugin and "clock" in data and data["environment"]["glass"] is False:
        print("%s\t%s\t%s" % (scenario, os.path.join(repo, "plugins", plugin), data["id"]))
        sys.exit(0)
sys.exit(1)
PY
IFS=$'\t' read -r SCENARIO PLUGIN SCENARIO_ID <"$WORK/pick.tsv"
echo "NOTE 演练场景：${SCENARIO#$AUTHOR/}"

# 1. validate
cli validate "$PLUGIN" >"$WORK/validate.out" 2>&1; check "validate 通过" 0 $?

# 2. run → 读报告 → 看截图
run_scenario() { # 输出名 场景文件
  cli run "$PLUGIN" --preview-tool "$APP" --scenario "$2" --out "$WORK/$1" --json >"$WORK/$1.json" 2>"$WORK/$1.err"
}
run_scenario run1 "$SCENARIO"; code=$?
if [ "$code" -eq 4 ]; then echo "SKIP: 预览环境不可用（无图形会话或无屏幕录制授权）" >&2; exit 77; fi
check "run 成功" 0 $code
python3 -I - "$WORK/run1/report.json" "$WORK/run1/preview.png" "$WORK/author/node_modules/@switchly/plugin-cli/src/png.js" <<'PY'
import json, subprocess, sys
report = json.load(open(sys.argv[1]))
assert report["status"] == "passed", "report.status"
assert report["environment"]["deterministicClock"] is True
script = 'import("%s").then(async m => { const fs = await import("node:fs"); const img = m.decodePng(fs.readFileSync("%s")); const seen = new Set(); for (let i = 0; i < img.rgba.length; i += 4) { seen.add(img.rgba[i] << 16 | img.rgba[i+1] << 8 | img.rgba[i+2]); if (seen.size > 8) break; } console.log(img.width + "x" + img.height + " colors>=" + seen.size); process.exit(seen.size >= 3 && img.width > 0 ? 0 : 1); })' % (sys.argv[3], sys.argv[2])
print(subprocess.run(["node", "-e", script], capture_output=True, text=True).stdout.strip())
subprocess.run(["node", "-e", script], check=True, capture_output=True)
PY
check "报告 passed、截图可解码且不是空白" 0 $?

# 3. 基线闭环：接受 → 改动后检出 → 恢复后通过
cli baseline accept "$WORK/run1" --baseline-dir "$WORK/baselines" --json >/dev/null 2>&1; check "接受基线" 0 $?
python3 -I - "$SCENARIO" "$WORK/changed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["environment"]["contentWidthPoints"] = d["environment"]["contentWidthPoints"] - 40   # 改动：收窄内容宽度
json.dump(d, open(sys.argv[2], "w"))
PY
# 改动后的场景需要能找到 fixture：复制到原场景同目录再运行。
cp "$WORK/changed.json" "$(dirname "$SCENARIO")/__changed.json"
run_scenario run2 "$(dirname "$SCENARIO")/__changed.json"; check "改动后重跑成功" 0 $?
rm -f "$(dirname "$SCENARIO")/__changed.json"
# 同一逻辑身份（插件+场景 ID）：把改动场景的 id 保持不变，所以 compare 能找到基线。
cli baseline compare "$WORK/run2" --baseline-dir "$WORK/baselines" --out "$WORK/cmp-changed" --json >"$WORK/cmp-changed.json" 2>/dev/null; check "改动被检出（退出 1）" 1 $?
run_scenario run3 "$SCENARIO"; check "恢复后重跑成功" 0 $?
cli baseline compare "$WORK/run3" --baseline-dir "$WORK/baselines" --out "$WORK/cmp-fixed" --json >"$WORK/cmp-fixed.json" 2>/dev/null; check "恢复后与基线逐像素一致（退出 0）" 0 $?

# 4. 不泄露本机路径：作者可见的全部文本产物不得含宿主工作区、作者临时目录或用户主目录
LEAKS=""
for f in "$WORK"/run*/report.json "$WORK"/run*/ui-tree.json "$WORK"/run*/actions.json "$WORK"/cmp-*/compare-report.json "$WORK"/*.json "$WORK"/*.err; do
  [ -f "$f" ] || continue
  case "$f" in "$WORK/pick.tsv"|"$WORK/validate.out") continue;; esac
  if grep -q -e "$HOST_ROOT" -e "$WORK" -e "${HOME:-/nonexistent-home}" "$f" 2>/dev/null; then LEAKS="$LEAKS $(basename "$f")"; fi
done
[ -z "$LEAKS" ] && pass "作者可见产物不含本机绝对路径" || fail "产物泄露本机路径：$LEAKS"

# 5. 干净环境声明
[ ${#SANDBOX[@]} -gt 0 ] && echo "NOTE 全程在禁网沙箱内运行" || echo "NOTE 本机没有 sandbox-exec，无法验证禁网"
echo "NOTE 全程 DEVELOPER_DIR=/nonexistent、HOME 为空目录、cwd 为独立作者目录"

[ "$failures" -eq 0 ] && echo "SUMMARY clean-room passed" || { echo "SUMMARY clean-room failed=$failures"; exit 1; }
