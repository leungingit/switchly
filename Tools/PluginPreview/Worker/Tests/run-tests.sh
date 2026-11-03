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
    Tools/PluginPreview/Worker/Tests/PluginPreviewWorkerTests.swift \
    -o "$build_dir/plugin-preview-worker-tests"

"$build_dir/plugin-preview-worker-tests"
