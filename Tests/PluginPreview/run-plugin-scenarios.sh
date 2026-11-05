#!/bin/bash
# T17 外仓场景回归：用预览工具运行插件仓库的全部场景。
#  - 每个场景必须 passed；
#  - 声明确定时钟且非玻璃的场景连跑两次，截图必须逐字节一致（可复现）；
#  - 玻璃场景只作为证据（passed 即可），不比较像素。
# 用法：run-plugin-scenarios.sh [插件仓库目录，默认 ../switchly-plugins]
# 前置：make plugin-preview-build；需要图形会话与屏幕录制授权。退出码：0 通过；1 失败；77 环境不可用。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app"
REPO="$(cd "${1:-$ROOT/../switchly-plugins}" 2>/dev/null && pwd)" || { echo "SKIP: 找不到插件仓库目录" >&2; exit 77; }
[ -d "$APP" ] || { echo "SKIP: 预览 App 未构建（先运行 make plugin-preview-build）" >&2; exit 77; }
[ -d "$REPO/preview/scenarios" ] || { echo "SKIP: $REPO 没有 preview/scenarios" >&2; exit 77; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-scenarios.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0; total=0

# 输出每个场景：<场景文件>\t<插件目录>\t<stable|evidence>。分组到插件的映射来自插件仓库自己的
# preview/scenario-plugins.json（外仓测试读取同一份）；分组缺失映射即报错，不靠 bundleID 猜测（多个插件可能匹配同一应用）。
python3 -I - "$REPO" >"$WORK/list.tsv" <<'PY' || { echo "FAIL 场景清单解析失败（分组缺少插件映射）" >&2; exit 1; }
import glob, json, os, sys
repo = sys.argv[1]
mapping = json.load(open(os.path.join(repo, "preview", "scenario-plugins.json")))
root = os.path.join(repo, "preview", "scenarios")
for scenario in sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True)):
    relative = os.path.relpath(scenario, root)
    if "fixtures" in relative.split(os.sep):
        continue
    group = relative.split(os.sep)[0]
    plugin_id = mapping.get(group)
    plugin_dir = os.path.join(repo, "plugins", plugin_id or "")
    if not plugin_id or not os.path.isdir(plugin_dir):
        sys.exit("scenario group %s has no plugin mapping" % group)
    data = json.load(open(scenario))
    stable = "clock" in data and data["environment"]["glass"] is False
    print("%s\t%s\t%s" % (scenario, plugin_dir, "stable" if stable else "evidence"))
PY

run_once() { # 名称 插件目录 场景
  node "$ROOT/Plugins/cli/bin/switchly-plugin.js" run "$2" --preview-tool "$APP" --scenario "$3" --out "$WORK/$1" --json >"$WORK/$1.json" 2>/dev/null
  local code=$?
  if [ "$code" -eq 4 ]; then echo "SKIP: 预览环境不可用（无图形会话或无屏幕录制授权）" >&2; exit 77; fi
  return "$code"
}

index=0
while IFS=$'\t' read -r scenario plugin kind; do
  index=$((index + 1)); total=$((total + 1))
  label="${scenario#$REPO/preview/scenarios/}"
  run_once "a$index" "$plugin" "$scenario"
  if [ $? -ne 0 ]; then echo "FAIL ${label}: 运行未通过"; failures=$((failures + 1)); continue; fi
  if [ "$kind" = "stable" ]; then
    run_once "b$index" "$plugin" "$scenario"
    if cmp -s "$WORK/a$index/preview.png" "$WORK/b$index/preview.png"; then echo "PASS ${label}（确定性：两次截图逐字节一致）"
    else echo "FAIL ${label}: 确定时钟下两次截图不一致"; failures=$((failures + 1)); fi
  else
    echo "PASS ${label}（证据场景：passed，不比较像素）"
  fi
done <"$WORK/list.tsv"

[ "$failures" -eq 0 ] && echo "SUMMARY plugin-scenarios passed total=$total" || { echo "SUMMARY plugin-scenarios failed=$failures total=$total"; exit 1; }
