#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
temp_root=$(getconf DARWIN_USER_TEMP_DIR)
build_dir=$(mktemp -d "${temp_root%/}/switchly-preview-process-supervisor.XXXXXX")

cleanup() {
    find "$build_dir" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

arch=$(uname -m)
binary="$build_dir/ProcessSupervisorTests"

cd "$repo_root"
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
    Sources/Utilities/AppLogger.swift \
    Tools/PluginPreview/Protocol/PluginPreviewFrameCodec.swift \
    Tools/PluginPreview/Controller/PluginPreviewProcessTypes.swift \
    Tools/PluginPreview/Controller/PluginPreviewPipeIO.swift \
    Tools/PluginPreview/Controller/PluginPreviewWorkerSupervisor.swift \
    Tests/PluginPreview/ProcessSupervisorTests.swift \
    -o "$binary"

"$binary"
