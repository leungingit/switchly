#!/bin/bash
# T18 工具包验收：只使用解包后的工具包（不依赖仓库源码、Xcode 或网络）运行预览。
# 用法：run-toolkit-tests.sh <switchly-plugin-preview-toolkit-<版本>.tar.gz>
# 插件与场景取自仓库内的夹具（仅作为"插件作者的输入"），工具链全部来自解包目录。
# 需要图形会话与屏幕录制授权。退出码：0 通过；1 失败；77 环境不可用。
set -uo pipefail
[ $# -eq 1 ] && [ -f "$1" ] || { echo "用法：$0 <工具包.tar.gz>" >&2; exit 2; }
TARBALL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SELF_DIR/Fixtures/native-input"
NODE_DIR="$(dirname "$(command -v node)")"
# 解压到全新的空目录；脚本与夹具在别处，不在解压目录内执行任何东西。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-toolkit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXTRACT="$WORK/extract"; mkdir -p "$EXTRACT" "$WORK/home" "$WORK/cache" "$WORK/project"
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1（期望 $2，实际 $3）"; fi; }

# 1. 校验和与解包
SUM_FILE="$TARBALL.sha256"
if [ -f "$SUM_FILE" ]; then (cd "$(dirname "$TARBALL")" && shasum -a 256 -c "$(basename "$SUM_FILE")" >/dev/null 2>&1); check "tar.gz 校验和" 0 $?; else fail "缺少 $SUM_FILE"; fi
tar -xzf "$TARBALL" -C "$EXTRACT" || { fail "解包失败"; exit 1; }
KIT="$(find "$EXTRACT" -maxdepth 1 -mindepth 1 -type d | head -1)"
(cd "$KIT" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); check "包内 SHA256SUMS 全部匹配" 0 $?
APP="$KIT/SwitchlyPluginPreview.app"
EXE="$APP/Contents/MacOS/SwitchlyPluginPreview"

# 2. 清单与 App 自报版本一致；无源码/私有签名
python3 -I - "$KIT/toolkit-manifest.json" "$("$EXE" --version-json)" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1])); tool = json.loads(sys.argv[2])
for key in ("toolVersion", "protocolVersion", "scenarioSchemaVersion", "pluginAPIVersions", "sdkContractHash", "rendererRevision"):
    if manifest["tool"][key] != tool[key]:
        sys.exit("manifest.%s 与 App 自报不一致" % key)
PY
check "清单与 App --version-json 一致" 0 $?
[ -z "$(find "$KIT" \( -name '*.swift' -o -name '*.xcconfig' -o -name '*.pbxproj' -o -name 'project.yml' \) | head -1)" ]; check "不含源码/工程/签名配置文件" 0 $?
# 先捕获再匹配：pipefail 下 `codesign | grep -q` 会因 grep 提前退出让 codesign 收到 SIGPIPE（141）而偶发误报。
SIGNATURE_INFO="$(codesign -dv "$APP" 2>&1)"
grep -q "Signature=adhoc" <<<"$SIGNATURE_INFO"; check "ad-hoc 签名（无私有身份）" 0 $?

# 3. 离线安装 CLI（空 npm 缓存 + --offline：任何联网需求都会失败）
CLI_TGZ="$(find "$KIT" -maxdepth 1 -name 'switchly-plugin-cli-*.tgz' | head -1)"
(cd "$WORK/project" && npm init -y >/dev/null 2>&1 && HOME="$WORK/home" npm install --offline --no-audit --no-fund --cache "$WORK/cache" "$CLI_TGZ" >/dev/null 2>&1)
check "离线安装 CLI" 0 $?
CLI="$WORK/project/node_modules/.bin/switchly-plugin"
[ -x "$CLI" ]; check "CLI 可执行文件已安装" 0 $?

# 4. 干净环境：无 Xcode（DEVELOPER_DIR 指向不存在的目录）、无联网（沙箱拒绝全部网络）、HOME 为空目录
CLEAN_ENV=(env -i PATH="$NODE_DIR:/usr/bin:/bin" HOME="$WORK/home" TMPDIR="$WORK" DEVELOPER_DIR=/nonexistent)
SANDBOX=()
if command -v sandbox-exec >/dev/null 2>&1; then SANDBOX=(sandbox-exec -p '(version 1)(allow default)(deny network*)'); fi
cp -R "$FIXTURE/plugin" "$WORK/plugin"
python3 -I - "$FIXTURE/scenario.json" "$WORK/scenario.json" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
json.dump(dict(base, id="toolkit"), open(sys.argv[2], "w"))   # 保留夹具的 nativeClick 步骤与确定时钟
PY
run_with() { # 输出目录 [预览工具 App 路径]
  "${CLEAN_ENV[@]}" "${SANDBOX[@]}" "$CLI" run "$WORK/plugin" --preview-tool "${2:-$APP}" --scenario "$WORK/scenario.json" --out "$1" --json >"$1.json" 2>"$1.err"
}
run_with "$WORK/out-native"; code=$?
if [ "$code" -eq 4 ]; then echo "SKIP: 预览环境不可用（无图形会话或无屏幕录制授权）" >&2; exit 77; fi
check "无 Xcode、无网络、空 HOME 下运行（含 7 个步骤）" 0 $code
python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1])); e = json.load(open(sys.argv[2])).get("environment", {})
ok = r["status"] == "passed" and len(r["steps"]) == 7 and all(s["status"] == "passed" for s in r["steps"])
sys.exit(0 if ok else 1)' "$WORK/out-native.json" "$WORK/out-native/report.json"; check "步骤全部 passed" 0 $?
[ -s "$WORK/out-native/preview.png" ]; check "生成截图" 0 $?
if [ ${#SANDBOX[@]} -eq 0 ]; then echo "NOTE 本机没有 sandbox-exec，无法验证「禁用网络」"; fi
HOST_ARCH="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["environment"]["architecture"])' "$WORK/out-native/report.json")"
echo "NOTE 原生架构运行：$HOST_ARCH"

# 5. 另一架构（Rosetta）：包装 App 以 arch -x86_64 启动同一个预览可执行文件；Rosetta 不可用则明确标注未验证
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  WRAP="$WORK/wrap/SwitchlyPluginPreview.app/Contents/MacOS"; mkdir -p "$WRAP"
  printf '#!/bin/bash\nexec arch -x86_64 "%s" "$@"\n' "$EXE" >"$WRAP/SwitchlyPluginPreview"; chmod +x "$WRAP/SwitchlyPluginPreview"
  run_with "$WORK/out-x86" "$WORK/wrap/SwitchlyPluginPreview.app"; check "x86_64（Rosetta）下运行" 0 $?
  X86_ARCH="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["environment"]["architecture"])' "$WORK/out-x86/report.json" 2>/dev/null)"
  check "报告确认运行架构为 x86_64" "x86_64" "$X86_ARCH"
else
  echo "NOTE Rosetta 不可用：x86_64 未验证，不得标注为支持"
fi

# 6. 版本不配套时在启动前被拒绝（用同一 App 的错误契约哈希模拟）：篡改 CLI 的随包契约
TAMPER="$WORK/project/node_modules/@switchly/plugin-cli/contract/preview-scenario.schema.json"
[ -f "$TAMPER" ] || TAMPER="$(find "$WORK/project/node_modules" -path '*contract/preview-scenario.schema.json' | head -1)"
echo " " >>"$TAMPER"
run_with "$WORK/out-mismatch"; code=$?
check "契约被篡改（与 App 不配套）时 CLI 拒绝，退出码 4" 4 $code
python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["error"]["code"]=="incompatible-preview-tool" else 1)' "$WORK/out-mismatch.json"; check "诊断码为 incompatible-preview-tool" 0 $?

[ "$failures" -eq 0 ] && echo "SUMMARY toolkit passed" || { echo "SUMMARY toolkit failed=$failures"; exit 1; }
