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
    Models/Plugins/PluginManifest.swift \
    Models/Plugins/PluginGrant.swift \
    Models/Plugins/PluginUINode.swift \
    Models/Plugins/PluginScene.swift \
    Services/Plugins/PluginRegistry.swift \
    Services/Plugins/PluginPackageValidator.swift \
    Services/Plugins/PluginRuntime.swift \
    Services/Plugins/PluginFileReader.swift \
    Services/Plugins/PluginStorage.swift \
    Services/Plugins/MediaBridge.swift \
    Utilities/AppLogger.swift \
    Tools/PluginPreview/Protocol/PluginPreviewFrameCodec.swift \
    Tools/PluginPreview/Scenario/PreviewScenario.swift \
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
    Models/Plugins/PluginScene.swift \
    Models/Plugins/PluginUINode.swift \
    Models/Plugins/PluginManifest.swift \
    Services/Plugins/PluginRegistry.swift \
    Services/Plugins/PluginPackageValidator.swift \
    Services/Plugins/PluginStorage.swift \
    Utilities/AppLogger.swift \
    Tools/PluginPreview/Protocol/PluginPreviewFrameCodec.swift \
    Tools/PluginPreview/Worker/PluginPreviewWorkerProtocol.swift \
    Tools/PluginPreview/Controller/PluginPreviewProcessTypes.swift \
    Tools/PluginPreview/Controller/PluginPreviewPipeIO.swift \
    Tools/PluginPreview/Controller/PluginPreviewWorkerSupervisor.swift \
    Tools/PluginPreview/Controller/PluginPreviewSession.swift \
    Tests/PluginPreview/SessionTests.swift \
    -o "$binary"

"$binary" --real-worker "$worker_binary"
