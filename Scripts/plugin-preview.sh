#!/usr/bin/env bash
# 用本仓库的 CLI 与 Debug 预览 App 预览独立插件。
# 用法：PLUGIN=<插件目录> SCENARIO=<场景.json> Scripts/plugin-preview.sh <dev|run>
# 可选：PREVIEW_APP 指定预览 App（默认 make plugin-preview-app 的 Debug 产物）；OUT 指定 run 的输出目录（须为新目录）。
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

: "${PLUGIN:?请设置 PLUGIN=<插件目录>}"
: "${SCENARIO:?请设置 SCENARIO=<场景.json>}"
app=${PREVIEW_APP:-$root/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app}
[ -d "$app" ] || { echo "未找到预览 App：$app（先执行 mise run preview:app，或设置 PREVIEW_APP）" >&2; exit 4; }
cli=(node "$root/packages/plugin-cli/bin/switchly-plugin.js")

case "${1:-}" in
  dev) exec "${cli[@]}" dev "$PLUGIN" --preview-tool "$app" --scenario "$SCENARIO" ;;
  run)
    out=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/switchly-preview.XXXXXX")/out}
    "${cli[@]}" run "$PLUGIN" --preview-tool "$app" --scenario "$SCENARIO" --out "$out" --json
    echo "输出目录：$out（请打开 preview.png 核对画面）" >&2 ;;
  *) echo "usage: $0 <dev|run>" >&2; exit 2 ;;
esac
