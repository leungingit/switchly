#!/bin/bash
# 计算预览公共契约哈希：对 Plugins/api 下 6 个契约文件按文件名排序，
# 逐个取 sha256，再对 "<sha256>  <文件名>" 清单取 sha256。
# 用法：contract-hash.sh          输出哈希
#       contract-hash.sh --check  与 PluginPreviewContract.swift 中常量比对，不一致则非零退出
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
files=(preview-activity-fixture.schema.json capabilities.json manifest.schema.json preview-fs-fixture.schema.json preview-media-fixture.schema.json preview-scenario.schema.json preview-weather-fixture.schema.json)
hash=$(for f in "${files[@]}"; do (cd "$root/Plugins/api" && shasum -a 256 "$f"); done | shasum -a 256 | cut -d' ' -f1)
hash="sha256:$hash"
if [ "${1:-}" = "--check" ]; then
  declared=$(grep 'sdkContractHash' "$root/Tools/PluginPreview/Worker/PluginPreviewWorkerProtocol.swift" | grep -o 'sha256:[0-9a-f]\{64\}' | head -1)
  if [ "$declared" != "$hash" ]; then
    echo "契约哈希不一致：常量=$declared 实际=$hash" >&2; exit 1
  fi
  echo "契约哈希一致：$hash"
else
  echo "$hash"
fi
