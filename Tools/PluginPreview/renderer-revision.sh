#!/bin/bash
# 计算预览渲染器 revision：对共享渲染源码（宿主与预览共用）按路径排序逐个取 sha256，
# 再对清单取 sha256。这些文件变化会使视觉基线失效，必须同步更新常量并重新接受基线。
# 用法：renderer-revision.sh          输出 revision
#       renderer-revision.sh --check  与 PluginPreviewWorkerProtocol.swift 中常量比对，不一致则非零退出
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
files=(
  Sources/Models/Plugins/PluginScene.swift
  Sources/Models/Plugins/PluginUINode.swift
  Sources/Models/Plugins/PluginTimelineItem.swift
  Sources/Models/Plugins/SceneEvaluator.swift
  Sources/Utilities/DesignTokens.swift
  Sources/Utilities/GlassEffect.swift
  Sources/Utilities/MotionTokens.swift
  Sources/Utilities/NativeCrystalContainer.swift
  Sources/Utilities/ThemeApplier.swift
  Sources/Views/PluginActivityImage.swift
  Sources/Views/PluginLineChart.swift
  Sources/Views/PluginTimelineView.swift
  Sources/Views/PluginOverlayView.swift
  Sources/Views/PluginSceneDrawing.swift
  Sources/Views/PluginSceneView.swift
  Sources/Views/PluginSlotSurface.swift
)
revision=$(for f in "${files[@]}"; do (cd "$root" && shasum -a 256 "$f"); done | shasum -a 256 | cut -d' ' -f1)
revision="sha256:$revision"
if [ "${1:-}" = "--check" ]; then
  declared=$(grep 'rendererRevision' "$root/Tools/PluginPreview/Worker/PluginPreviewWorkerProtocol.swift" | grep -o 'sha256:[0-9a-f]\{64\}' | head -1)
  if [ "$declared" != "$revision" ]; then
    echo "渲染器 revision 不一致：常量=$declared 实际=${revision}（更新常量并重新接受视觉基线）" >&2; exit 1
  fi
  echo "渲染器 revision 一致：$revision"
else
  echo "$revision"
fi
