#!/bin/bash
# 把已构建的预览 App 与 CLI 打成离线工具包（T18）。
# 用法：package-toolkit.sh <SwitchlyPluginPreview.app> <输出目录>
# 输出：<输出目录>/switchly-plugin-preview-toolkit-<版本>/（App、CLI tarball、manifest、校验和、说明）
#       以及同名 .tar.gz 与 .tar.gz.sha256。
# 工具包不含宿主源码与私有签名配置：自检要求 ad-hoc 签名、无源码文件，否则非零退出。
set -euo pipefail
[ $# -eq 2 ] || { echo "用法：$0 <SwitchlyPluginPreview.app> <输出目录>" >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
exe="$app/Contents/MacOS/SwitchlyPluginPreview"
worker="$app/Contents/MacOS/SwitchlyPluginPreviewWorker"
[ -x "$exe" ] && [ -x "$worker" ] || { echo "App 缺少可执行文件或内置 worker：$app" >&2; exit 1; }

version_json="$("$exe" --version-json)"
field() { python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" <<<"$version_json"; }
tool_version="$(field toolVersion)"
name="switchly-plugin-preview-toolkit-$tool_version"
stage="$out/$name"
[ ! -e "$stage" ] || { echo "输出已存在，拒绝覆盖：$stage" >&2; exit 1; }

# 自检：签名必须是 ad-hoc（不得带入私有签名身份）。
signature="$(codesign -dv "$app" 2>&1 || true)"
if ! grep -q "Signature=adhoc" <<<"$signature"; then
  echo "App 不是 ad-hoc 签名，可能带入了私有签名身份；请用 make plugin-preview-package 构建。" >&2
  grep -E "Authority|TeamIdentifier" <<<"$signature" >&2 || true
  exit 1
fi

mkdir -p "$stage"
ditto "$app" "$stage/SwitchlyPluginPreview.app"
# 自检：包内不得出现源码、工程或签名配置文件。
leak="$(find "$stage" \( -name '*.swift' -o -name '*.xcconfig' -o -name '*.pbxproj' -o -name 'project.yml' -o -name '*.p12' -o -name '*.mobileprovision' \) | head -5)"
[ -z "$leak" ] || { echo "工具包含不应分发的文件：$leak" >&2; rm -rf "$stage"; exit 1; }

# CLI：npm pack 会先执行 prepack 复制随包契约；tarball 只含 bin/src/contract/scripts。
# 注意：npm pack 打包的是当前目录的包，--prefix 不会改变它，必须在包目录内执行。
tgz="$(cd "$root/Plugins/cli" && npm pack --pack-destination "$stage" --silent 2>/dev/null | tail -1)"
[ -n "$tgz" ] && [ -f "$stage/$tgz" ] || { echo "CLI 打包失败" >&2; rm -rf "$stage"; exit 1; }

archs="$(lipo -archs "$exe")"
min_os="$(vtool -show-build "$exe" 2>/dev/null | awk '/minos/ {print $2; exit}')"
cli_version="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$root/Plugins/cli/package.json")"
# 漂移检查：CLI 与预览工具必须同版本发布，否则工具包的「配套」语义失效。
if [ "$cli_version" != "$tool_version" ]; then
  echo "CLI 版本 $cli_version 与预览工具版本 $tool_version 不一致；请同步 Plugins/cli/package.json 与 PluginPreviewContract.toolVersion。" >&2
  rm -rf "$stage"; exit 1
fi
cli_sha="$(shasum -a 256 "$stage/$tgz" | cut -d' ' -f1)"

python3 -I - "$stage/toolkit-manifest.json" "$version_json" "$tgz" "$cli_version" "$cli_sha" "$archs" "$min_os" <<'PY'
import json, sys
path, version_json, tgz, cli_version, cli_sha, archs, min_os = sys.argv[1:8]
tool = json.loads(version_json)
manifest = {
    "schemaVersion": 1,
    "toolkitVersion": tool["toolVersion"],
    "tool": {k: tool[k] for k in ("toolVersion", "protocolVersion", "scenarioSchemaVersion", "pluginAPIVersions", "sdkContractHash", "rendererRevision")},
    "cli": {"file": tgz, "version": cli_version, "sha256": "sha256:" + cli_sha},
    "app": {"path": "SwitchlyPluginPreview.app", "architectures": archs.split(), "minimumOS": min_os, "signature": "adhoc"},
    "notes": "architectures 仅表示二进制包含的切片；是否经实测见 docs/plugins/preview/plugin-preview-coverage.md。包为本地候选：未做 Developer ID 签名与公证。",
}
json.dump(manifest, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY

cat >"$stage/README.txt" <<README
Switchly 插件独立预览工具包 ${tool_version}（本地候选，未做 Developer ID 签名与公证）

安装 CLI（离线，无需联网）：
  npm install --offline ./${tgz}        # 在你的插件项目中；或 npm install -g ./${tgz}
运行（无需 Xcode，不需要 Switchly 本体在运行）：
  switchly-plugin run <插件目录> --preview-tool ./SwitchlyPluginPreview.app --scenario <场景.json> --out <输出目录> --json
  switchly-plugin dev <插件目录> --preview-tool ./SwitchlyPluginPreview.app --scenario <场景.json>
CLI 与 App 必须使用同一工具包；版本、协议或契约不一致时 CLI 会在启动前拒绝并说明原因。
截图需要图形会话与屏幕录制授权；不可用时返回环境错误（退出码 4），不会伪造通过。
校验：在本目录运行  shasum -a 256 -c SHA256SUMS
README

(cd "$stage" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 > SHA256SUMS)
(cd "$out" && tar -czf "$name.tar.gz" "$name" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
echo "工具包已生成：$out/$name.tar.gz"
echo "  版本 $tool_version  架构 $archs  最低系统 ${min_os:-未知}  CLI $tgz"
