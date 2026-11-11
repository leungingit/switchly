#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-preview-watch.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_DIR"' EXIT
cd "$ROOT"
xcrun swiftc -swift-version 5 -parse-as-library \
  Sources/Models/Plugins/PluginManifest.swift Sources/Models/Plugins/PluginUINode.swift Sources/Models/Plugins/PluginScene.swift \
  Sources/Models/Plugins/PluginScene3DDescriptor.swift Sources/Services/Plugins/PluginSurfaceRequest.swift \
  Sources/Services/Plugins/GLBPreflight.swift \
  Sources/Services/Plugins/PluginRegistry.swift Sources/Services/Plugins/PluginPackageValidator.swift Sources/Utilities/AppLogger.swift \
  Tools/PluginPreview/Scenario/PluginPreviewStep.swift Tools/PluginPreview/Scenario/PreviewScenario.swift \
  Tools/PluginPreview/Artifacts/PluginPreviewArtifactModels.swift \
  Tools/PluginPreview/Reload/PluginPreviewPackageWatcher.swift Tests/PluginPreview/PackageWatcherTests.swift \
  -o "$TEST_DIR/watcher-tests"
"$TEST_DIR/watcher-tests"
