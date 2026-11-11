#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/switchly-preview-worker-tests.XXXXXX")
cleanup() {
    python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$build_dir"
}
trap cleanup EXIT

cd "$repo_root"
xcrun swiftc -swift-version 5 -D PLUGIN_PREVIEW_WORKER_TESTS \
    Sources/Models/Plugins/PluginConsoleLine.swift \
    Sources/Models/Plugins/PluginManifest.swift \
    Sources/Models/Plugins/PluginGrant.swift \
    Sources/Models/Plugins/PluginUINode.swift \
    Sources/Models/Plugins/PluginScene.swift \
    Sources/Models/Plugins/PluginScene3DDescriptor.swift \
    Sources/Services/Plugins/PluginSurfaceRequest.swift \
    Sources/Services/Plugins/GLBPreflight.swift \
    Sources/Services/Plugins/PluginRegistry.swift \
    Sources/Services/Plugins/PluginPackageValidator.swift \
    Sources/Services/Plugins/PluginRuntime.swift \
    Sources/Services/Plugins/PluginVirtualClock.swift \
    Sources/Services/Plugins/PluginFileReader.swift \
    Sources/Services/Plugins/PluginStorage.swift \
    Sources/Services/Plugins/MediaBridge.swift \
    Sources/Services/Plugins/MediaReadContext.swift \
    Sources/Services/Plugins/PluginLifetime.swift \
    Sources/Utilities/AppLogger.swift \
    Tools/PluginPreview/Protocol/PluginPreviewFrameCodec.swift \
    Tools/PluginPreview/Scenario/PreviewScenario.swift \
    Tools/PluginPreview/Scenario/PluginPreviewStep.swift \
    Tools/PluginPreview/Fixtures/PluginFixtureFileReader.swift \
    Tools/PluginPreview/Worker/PluginPreviewWorkerProtocol.swift \
    Tools/PluginPreview/Worker/PluginPreviewWorkerFixtures.swift \
    Tools/PluginPreview/Worker/PluginPreviewWorkerSession.swift \
    Tools/PluginPreview/Worker/PluginPreviewWorkerService.swift \
    Tools/PluginPreview/Worker/Tests/PluginPreviewWorkerTests.swift \
    -o "$build_dir/plugin-preview-worker-tests"

"$build_dir/plugin-preview-worker-tests"
