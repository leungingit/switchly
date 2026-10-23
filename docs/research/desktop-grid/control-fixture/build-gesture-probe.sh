#!/usr/bin/env bash
set -euo pipefail

fixture_sources="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# GRID_PROBE_BUILD_ROOT 与 build-fixtures.sh 含义相同；默认放到系统临时目录 $TMPDIR/desktop-grid-gesture。
probe_root="${GRID_PROBE_BUILD_ROOT:-${TMPDIR:-/tmp}/desktop-grid-gesture}"
mkdir -p "$probe_root"

# 私有框架全部由 dlopen/dlsym 运行时解析，不链接 MultitouchSupport。
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  "$fixture_sources/gesture-probe.m" \
  -o "$probe_root/gesture-probe"

# 仅 ad-hoc 签名；不借用其他 App 的身份，不改 TCC。
codesign -s - -f "$probe_root/gesture-probe" >/dev/null 2>&1

# Build only. 运行需用户在终端里显式执行。
printf '%s\n' "$probe_root/gesture-probe"
