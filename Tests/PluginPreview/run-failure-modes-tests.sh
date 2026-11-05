#!/bin/bash
# 失败模式回归：每种常见错误必须得到稳定、可区分的 状态 + 错误码 + 退出码（而不是笼统的 preview-failed）。
# 这张表同时是 docs/plugin-preview-guide.md「错误修复」一节的事实来源。
# 前置：make plugin-preview-build；需要图形会话。退出码：0 通过；1 失败；77 环境不可用。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app"
[ -d "$APP" ] || { echo "SKIP: 预览 App 未构建（先运行 make plugin-preview-build）" >&2; exit 77; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-failure-modes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

python3 -I - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
def plugin(name, source, manifest_raw=None):
    d = os.path.join(work, "plugin-" + name); os.makedirs(d)
    manifest = {"id": "com.example.fm", "name": {"en": "FM"}, "version": "1", "apiVersion": 2,
                "matches": ["com.example.app"], "permissions": [], "entry": "main.js"}
    open(os.path.join(d, "manifest.json"), "w").write(manifest_raw if manifest_raw is not None else json.dumps(manifest))
    open(os.path.join(d, "main.js"), "w").write(source)
render = lambda body: "globalThis.__switchlyPlugin={render(){%s}};" % body
plugin("good", render('return [{slot:"center",node:{type:"text",value:"ok"}}]'))
plugin("slotonly", render('return [{slot:"titleAccessory",node:{type:"badge",value:"Ready",tone:"accent"}}]'))
plugin("empty", render("return []"))
plugin("throws", render('throw new Error("boom")'))
plugin("invalid", render('return [{slot:"center",node:{type:"unknown"}}]'))
plugin("loop", render("while(true){}"))
plugin("badmanifest", "x", manifest_raw="{ broken")
base = {"schemaVersion": 1, "id": "fm", "environment": {"locale": "en", "appearance": "light", "glass": False,
        "reduceMotion": True, "contentWidthPoints": 320}, "target": {"bundleID": "com.example.app", "appName": "Example"}}
def scenario(name, mutate=lambda d: None):
    d = json.loads(json.dumps(base)); mutate(d)
    json.dump(d, open(os.path.join(work, "scn-%s.json" % name), "w"))
scenario("ok")
scenario("unknownkey", lambda d: d.update(bogus=1))
scenario("badlocale", lambda d: d["environment"].update(locale="fr"))
scenario("missingfixture", lambda d: d.update(fixtures={"media": "nope.json"}))
scenario("badstep", lambda d: d.update(steps=[{"type": "wait"}]))
scenario("grantsbeyondmanifest", lambda d: d.update(grants=["fs.read"]))
PY

# 名称 插件 场景 期望退出码 期望状态 期望错误码（passed 用 -）
expect_case() {
  local name="$1" plugin="$2" scn="$3" want_exit="$4" want_status="$5" want_code="$6" out code got
  out="$(node "$ROOT/Plugins/cli/bin/switchly-plugin.js" run "$WORK/plugin-$plugin" --preview-tool "$APP" --scenario "$WORK/scn-$scn.json" --out "$WORK/o-$name" --json 2>/dev/null)"
  code=$?
  got="$(printf '%s' "$out" | python3 -I -c '
import json, sys
try:
    r = json.load(sys.stdin)
    print(r.get("status"), (r.get("failure") or r.get("error") or {}).get("code", "-"))
except Exception:
    print("NOJSON -")')"
  if [ "$code" -eq 4 ] && [ "$want_exit" -ne 4 ]; then echo "SKIP: 预览环境不可用（无图形会话）" >&2; exit 77; fi
  if [ "$code" = "$want_exit" ] && [ "$got" = "$want_status $want_code" ]; then echo "PASS $name → exit $code, $got"
  else echo "FAIL $name: want exit $want_exit [$want_status $want_code] got exit $code [$got]"; failures=$((failures + 1)); fi
}

expect_case "正常插件"                 good        ok                  0 passed -
expect_case "只渲染未接入的槽位"       slotonly    ok                  3 unsupported no-capturable-slot
expect_case "什么都没渲染"             empty       ok                  1 failed empty-render
expect_case "渲染时抛出异常"           throws      ok                  1 failed plugin-script-error
expect_case "返回非法 UI"              invalid     ok                  1 failed invalid-render-output
expect_case "manifest 损坏"            badmanifest ok                  1 failed invalid-package
expect_case "场景含未知字段"           good        unknownkey          1 failed invalid-scenario
expect_case "场景语言非法"             good        badlocale           1 failed invalid-scenario
expect_case "fixture 文件缺失"         good        missingfixture      1 failed invalid-fixture
expect_case "未知场景步骤类型"         good        badstep             3 unsupported unsupported
expect_case "授权超出 manifest（取交集）" good     grantsbeyondmanifest 0 passed -
expect_case "插件死循环（被终止）"     loop        ok                  1 failed plugin-timeout

# 临时文件卫生：用独立的 TMPDIR 运行，成功与失败的 run 结束后都不得在其中留下任何东西
# （对照实验显示正常结束的 run 本就不泄漏；本断言是回归防护，不证明某个修复。进程被信号杀死的路径不在此覆盖）。
mkdir -p "$WORK/private-tmp"
for pair in "good ok" "throws ok" "empty ok" "slotonly ok"; do
  set -- $pair
  TMPDIR="$WORK/private-tmp" node "$ROOT/Plugins/cli/bin/switchly-plugin.js" run "$WORK/plugin-$1" --preview-tool "$APP" \
    --scenario "$WORK/scn-$2.json" --out "$WORK/o-tmp-$1" --json >/dev/null 2>&1
done
leftover="$(ls -A "$WORK/private-tmp")"
if [ -z "$leftover" ]; then echo "PASS run 结束后不在 TMPDIR 留下任何临时文件（成功与 3 种失败路径）"
else echo "FAIL run 在 TMPDIR 留下了临时文件：$(echo "$leftover" | head -3 | tr '\n' ' ')"; failures=$((failures + 1)); fi

if pgrep -f "SwitchlyPluginPreviewWorker" >/dev/null 2>&1; then
  sleep 1
  pgrep -f "SwitchlyPluginPreviewWorker" >/dev/null 2>&1 && { echo "FAIL 死循环之后仍有 worker 进程残留"; failures=$((failures + 1)); } || echo "PASS 死循环的 worker 已被回收"
else echo "PASS 死循环的 worker 已被回收"; fi

[ "$failures" -eq 0 ] && echo "SUMMARY failure-modes passed" || { echo "SUMMARY failure-modes failed=$failures"; exit 1; }
