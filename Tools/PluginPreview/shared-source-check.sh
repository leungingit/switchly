#!/bin/bash
# 共享源码守卫（T17）：预览必须复用宿主的 Runtime / 解码器 / 渲染器，禁止在 Tools、Tests 中另造同名类型，
# 且预览与 worker target 必须编译宿主文件本身。违反即非零退出。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
types=(PluginTimelineItem PluginTimelineView PluginRuntime PluginRenderOutput PluginOverlayView PluginSceneView PluginPackageValidator PluginSlotSurface SceneDrawing PluginUINode PluginScene PluginFileReading MediaBridging Scene3DAccessibilityModel Scene3DCameraController Scene3DHitRouter Scene3DInputSession Scene3DPointerClassifier Scene3DHitTestAdapter Scene3DHitProviding PluginScene3DDescriptor PluginScene3DState PluginScene3DFailure PluginScene3DAsset PluginScene3DAssetCache PluginScene3DAssembly PluginScene3DController PluginScene3DSceneHosting PluginScene3DView PluginSurfaceRenderer PluginSurfaceRasterizing PluginSurfaceTexture PluginSurfaceRequest PluginSurfaceSignature PluginSurfaceContentValidator)
status=0
for name in "${types[@]}"; do
  defs=$(grep -rEn "^(final )?(class|struct|enum|protocol|indirect enum) $name\b" Sources Tools Tests 2>/dev/null || true)
  count=$(printf '%s' "$defs" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    echo "类型 $name 应只有一处定义，实际 $count 处：" >&2; printf '%s\n' "$defs" >&2; status=1
  elif grep -qE "^(Tools|Tests)/" <<<"$defs"; then
    echo "类型 $name 的定义位于 Tools/Tests（预览不得另造实现）：$defs" >&2; status=1
  fi
done
# 预览与 worker target 必须引用宿主文件本身（同一份源码），而不是拷贝。
for file in Sources/Models/Plugins/PluginTimelineItem.swift Sources/Views/PluginTimelineView.swift Sources/Services/Plugins/PluginRuntime.swift Sources/Models/Plugins/PluginUINode.swift Sources/Views/PluginOverlayView.swift Sources/Views/PluginSceneView.swift Sources/Views/PluginSlotSurface.swift Sources/Services/Plugins/PluginPackageValidator.swift Sources/Services/Plugins/GLBPreflight.swift Sources/Models/Plugins/PluginScene3DDescriptor.swift Sources/Services/Plugins/PluginSurfaceRasterizing.swift Sources/Services/Plugins/PluginSurfaceRenderer.swift Sources/Services/Plugins/PluginSurfaceRequest.swift Sources/Services/Plugins/PluginSurfaceSignature.swift Sources/Services/Plugins/PluginSurfaceTexture.swift Sources/Services/Plugins/PluginScene3DAsset.swift Sources/Services/Plugins/PluginScene3DAssetCache.swift Sources/Services/Plugins/PluginScene3DAssetLoader.swift Sources/Services/Plugins/PluginScene3DAssembly.swift Sources/Services/Plugins/PluginScene3DController.swift Sources/Views/Plugins/PluginScene3DView.swift Sources/Services/Plugins/Scene3DAccessibilityModel.swift Sources/Services/Plugins/Scene3DCameraController.swift Sources/Services/Plugins/Scene3DHitRouter.swift Sources/Services/Plugins/Scene3DInputSession.swift Sources/Services/Plugins/Scene3DPointerClassifier.swift Sources/Views/Plugins/Scene3DHitTestAdapter.swift; do
  if ! grep -q "^      - $file\$" project.yml; then echo "project.yml 的预览 target 未编译宿主文件 $file" >&2; status=1; fi
done
# T06 的共享加载器直接 import GLTFKit2；预览 target 必须声明同一包依赖，
# 否则同名源码只能在宿主 target 编译，预览会在链接阶段缺模块。
preview_target="$(sed -n '/^  SwitchlyPluginPreview:/,/^  SwitchlyPluginPreviewWorker:/p' project.yml)"
if ! grep -q '^      - package: GLTFKit2$' <<<"$preview_target"; then
  echo "project.yml 的预览 target 未声明 GLTFKit2 包依赖" >&2; status=1
fi
[ "$status" -eq 0 ] && echo "共享源码守卫通过：${#types[@]} 个核心类型各一处定义，预览 target 编译宿主源码"
exit "$status"
