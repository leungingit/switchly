#!/bin/bash
# 共享源码守卫（T17）：预览必须复用宿主的 Runtime / 解码器 / 渲染器，禁止在 Tools、Tests 中另造同名类型，
# 且预览与 worker target 必须编译宿主文件本身。违反即非零退出。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
types=(PluginRuntime PluginRenderOutput PluginOverlayView PluginSceneView PluginPackageValidator PluginSlotSurface SceneDrawing PluginUINode PluginScene PluginFileReading MediaBridging)
status=0
for name in "${types[@]}"; do
  defs=$(grep -rEn "^(final )?(class|struct|enum|protocol|indirect enum) $name\b" App Models Services Views ViewModels Utilities Tools Tests 2>/dev/null || true)
  count=$(printf '%s' "$defs" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    echo "类型 $name 应只有一处定义，实际 $count 处：" >&2; printf '%s\n' "$defs" >&2; status=1
  elif grep -qE "^(Tools|Tests)/" <<<"$defs"; then
    echo "类型 $name 的定义位于 Tools/Tests（预览不得另造实现）：$defs" >&2; status=1
  fi
done
# 预览与 worker target 必须引用宿主文件本身（同一份源码），而不是拷贝。
for file in Services/Plugins/PluginRuntime.swift Models/Plugins/PluginUINode.swift Views/PluginOverlayView.swift Views/PluginSceneView.swift Views/PluginSlotSurface.swift Services/Plugins/PluginPackageValidator.swift; do
  if ! grep -q "^      - $file\$" project.yml; then echo "project.yml 的预览 target 未编译宿主文件 $file" >&2; status=1; fi
done
[ "$status" -eq 0 ] && echo "共享源码守卫通过：${#types[@]} 个核心类型各一处定义，预览 target 编译宿主源码"
exit "$status"
