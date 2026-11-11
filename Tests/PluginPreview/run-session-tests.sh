#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
temp_root=$(getconf DARWIN_USER_TEMP_DIR)
build_dir=$(mktemp -d "${temp_root%/}/switchly-preview-session.XXXXXX")

cleanup() {
    find "$build_dir" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

arch=$(uname -m)
binary="$build_dir/SessionTests"
worker_binary="$build_dir/PluginPreviewWorker"

cd "$repo_root"
xcrun swiftc \
    -swift-version 5 \
    -target "$arch-apple-macosx12.0" \
    -parse-as-library \
    Sources/Models/Plugins/PluginManifest.swift \
    Sources/Models/Plugins/PluginConsoleLine.swift \
    Sources/Models/Plugins/PluginGrant.swift \
    Sources/Models/Plugins/PluginUINode.swift \
    Sources/Models/Plugins/PluginScene3DDescriptor.swift \
    Sources/Services/Plugins/PluginSurfaceRequest.swift \
    Sources/Models/Plugins/PluginScene.swift \
    Sources/Services/Plugins/PluginRegistry.swift \
    Sources/Services/Plugins/PluginPackageValidator.swift \
    Sources/Services/Plugins/GLBPreflight.swift \
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
    Tests/PluginPreview/RealWorkerMain.swift \
    -o "$worker_binary"

xcrun swiftc \
    -swift-version 5 \
    -target "$arch-apple-macosx12.0" \
    -parse-as-library \
    Sources/Models/Plugins/PluginScene.swift \
    Sources/Models/Plugins/PluginUINode.swift \
    Sources/Models/Plugins/PluginScene3DDescriptor.swift \
    Sources/Services/Plugins/PluginSurfaceRequest.swift \
    Sources/Models/Plugins/PluginManifest.swift \
    Sources/Services/Plugins/PluginRegistry.swift \
    Sources/Services/Plugins/PluginPackageValidator.swift \
    Sources/Services/Plugins/GLBPreflight.swift \
    Sources/Services/Plugins/PluginStorage.swift \
    Sources/Utilities/AppLogger.swift \
    Tools/PluginPreview/Protocol/PluginPreviewFrameCodec.swift \
    Sources/Models/Plugins/PluginConsoleLine.swift \
    Tools/PluginPreview/Worker/PluginPreviewWorkerProtocol.swift \
    Tools/PluginPreview/Controller/PluginPreviewProcessTypes.swift \
    Tools/PluginPreview/Controller/PluginPreviewPipeIO.swift \
    Tools/PluginPreview/Controller/PluginPreviewWorkerSupervisor.swift \
    Tools/PluginPreview/Controller/PluginPreviewSession.swift \
    Tests/PluginPreview/SessionTests.swift \
    -o "$binary"

"$binary" --real-worker "$worker_binary"
