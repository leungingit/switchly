#!/bin/bash
# 文档即被执行的命令：从 docs/plugins/plugin-preview-guide.md 原样提取 ```bash quickstart 与 ```bash agent-loop 两个块，
# 在解包后的工具包上、干净环境（无 Xcode、禁网沙箱）中依次执行。
# 用法：run-guide-check.sh <switchly-plugin-preview-toolkit-<版本>.tar.gz>
# 需要图形会话与屏幕录制授权。退出码：0 通过；1 失败；77 环境不可用。
set -uo pipefail
[ $# -eq 1 ] && [ -f "$1" ] || { echo "用法：$0 <工具包.tar.gz>" >&2; exit 2; }
TARBALL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUIDE="$ROOT/docs/plugins/plugin-preview-guide.md"
NODE_DIR="$(dirname "$(command -v node)")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-guide.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/kit" "$WORK/home" "$WORK/cache" "$WORK/cwd"

extract() { # 标记名 → 代码块内容
  python3 -I - "$GUIDE" "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"```bash %s\n(.*?)\n```" % re.escape(sys.argv[2]), text, re.S)
if not match:
    sys.exit("文档中找不到代码块：" + sys.argv[2])
print(match.group(1))
PY
}
extract quickstart >"$WORK/quickstart.sh" || exit 1
extract agent-loop >"$WORK/agent-loop.sh" || exit 1

tar -xzf "$TARBALL" -C "$WORK/kit"
KIT="$(find "$WORK/kit" -maxdepth 1 -mindepth 1 -type d | head -1)"
SANDBOX=()
command -v sandbox-exec >/dev/null 2>&1 && SANDBOX=(sandbox-exec -p '(version 1)(allow default)(deny network*)')
CLEAN_ENV=(env -i PATH="$NODE_DIR:/usr/bin:/bin" HOME="$WORK/home" TMPDIR="$WORK" DEVELOPER_DIR=/nonexistent KIT="$KIT" npm_config_cache="$WORK/cache")

(cd "$WORK/cwd" && "${CLEAN_ENV[@]}" "${SANDBOX[@]}" bash -e "$WORK/quickstart.sh")
code=$?
if [ "$code" -eq 4 ] || grep -q "environment-unavailable" "$WORK/cwd/hello-project/result.json" 2>/dev/null; then
  echo "SKIP: 预览环境不可用（无图形会话或无屏幕录制授权）" >&2; exit 77
fi
[ "$code" -eq 0 ] && echo "PASS quickstart 原样执行通过" || { echo "FAIL quickstart 退出码 $code"; exit 1; }
[ -s "$WORK/cwd/hello-project/out/preview.png" ] && echo "PASS 产出截图" || { echo "FAIL 没有截图"; exit 1; }

(cd "$WORK/cwd" && "${CLEAN_ENV[@]}" "${SANDBOX[@]}" bash -e "$WORK/agent-loop.sh")
code=$?
[ "$code" -eq 0 ] && echo "PASS agent-loop 原样执行通过" || { echo "FAIL agent-loop 退出码 $code"; exit 1; }
echo "SUMMARY guide passed"
