#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-plugin-preview-protocol.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

BIN="$BUILD_ROOT/PluginPreviewFrameCodecTests"
ARCH="$(uname -m)"

SOURCES=(
  "$ROOT/Sources/Models/Plugins/PluginScene.swift"
  "$ROOT/Sources/Models/Plugins/PluginUINode.swift"
  "$ROOT/Sources/Models/Plugins/PluginTimelineItem.swift"
  "$ROOT/Sources/Models/Plugins/PluginScene3DDescriptor.swift"
  "$ROOT/Sources/Services/Plugins/PluginSurfaceRequest.swift"
  "$ROOT/Sources/Models/Plugins/PluginManifest.swift"
  "$ROOT/Sources/Services/Plugins/PluginRegistry.swift"
  "$ROOT/Sources/Services/Plugins/PluginPackageValidator.swift"
  "$ROOT/Sources/Services/Plugins/GLBPreflight.swift"
  "$ROOT/Sources/Utilities/AppLogger.swift"
  "$ROOT/Tools/PluginPreview/Protocol/PluginPreviewFrameCodec.swift"
  "$ROOT/Tools/PluginPreview/Protocol/Tests/PluginPreviewFrameCodecTests.swift"
)

printf 'compile_target=%s-apple-macosx12.0\n' "$ARCH"
xcrun swiftc \
  -swift-version 5 \
  -target "$ARCH-apple-macosx12.0" \
  -parse-as-library \
  "${SOURCES[@]}" \
  -o "$BIN"

"$BIN"
