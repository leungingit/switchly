#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVIDENCE_ROOT="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-plugin-preview-t01.XXXXXX")"
BIN="$EVIDENCE_ROOT/T01Probe"
ARCH="$(uname -m)"

SOURCES=(
  "$ROOT/Sources/Models/AppSettings.swift"
  "$ROOT/Sources/Models/DockLayoutSpec.swift"
  "$ROOT/Sources/Models/Enums/GridBackground.swift"
  "$ROOT/Sources/Models/Enums/GridStyle.swift"
  "$ROOT/Sources/Models/Enums/NotificationStrategy.swift"
  "$ROOT/Sources/Models/Enums/PreviewHotspotEdge.swift"
  "$ROOT/Sources/Models/Enums/PreviewStrategy.swift"
  "$ROOT/Sources/Models/Enums/ShortcutPrefix.swift"
  "$ROOT/Sources/Models/Enums/ThumbnailSize.swift"
  "$ROOT/Sources/Models/MenuBarIcon.swift"
  "$ROOT/Sources/Models/MonitoredApp.swift"
  "$ROOT/Sources/Models/OnlineWeatherSettings.swift"
  "$ROOT/Sources/Models/UsageStatistics.swift"
  "$ROOT/Sources/Models/UsageStatisticsEfficiency.swift"
  "$ROOT/Sources/Models/Workspace.swift"
  "$ROOT/Sources/Models/Plugins/PluginGrant.swift"
  "$ROOT/Sources/Models/Plugins/PluginManifest.swift"
  "$ROOT/Sources/Models/Plugins/PluginScene.swift"
  "$ROOT/Sources/Models/Plugins/PluginUINode.swift"
  "$ROOT/Sources/Models/Plugins/SceneEvaluator.swift"
  "$ROOT/Sources/Services/Plugins/PluginRegistry.swift"
  "$ROOT/Sources/Services/Plugins/PluginPackageValidator.swift"
  "$ROOT/Sources/Utilities/AppLogger.swift"
  "$ROOT/Sources/Utilities/DesignTokens.swift"
  "$ROOT/Sources/Utilities/MotionTokens.swift"
  "$ROOT/Sources/Utilities/GlassEffect.swift"
  "$ROOT/Sources/Utilities/NativeCrystalContainer.swift"
  "$ROOT/Sources/Utilities/ThemeApplier.swift"
  "$ROOT/Sources/Views/PluginOverlayView.swift"
  "$ROOT/Sources/Views/PluginSceneView.swift"
  "$ROOT/Sources/Views/PluginSceneDrawing.swift"
  "$ROOT/Tools/PluginPreview/T01Probe.swift"
)

printf 'evidence_root=%s\n' "$EVIDENCE_ROOT"
printf 'compile_target=%s-apple-macosx12.0\n' "$ARCH"
xcrun swiftc \
  -swift-version 5 \
  -target "$ARCH-apple-macosx12.0" \
  -parse-as-library \
  "${SOURCES[@]}" \
  -o "$BIN"

set +e
"$BIN" offscreen --out "$EVIDENCE_ROOT/offscreen"
OFFSCREEN_STATUS=$?
"$BIN" plain --out "$EVIDENCE_ROOT/plain" "$@"
PLAIN_STATUS=$?
"$BIN" glass --out "$EVIDENCE_ROOT/glass" "$@"
GLASS_STATUS=$?
set -e

printf 'offscreen_status=%s\n' "$OFFSCREEN_STATUS"
printf 'plain_status=%s\n' "$PLAIN_STATUS"
printf 'glass_status=%s\n' "$GLASS_STATUS"

if [[ $PLAIN_STATUS -ne 0 || $GLASS_STATUS -ne 0 ]]; then
  printf 'core_window_capture=FAIL\n' >&2
  exit 1
fi

printf 'core_window_capture=PASS\n'
if [[ $OFFSCREEN_STATUS -ne 0 ]]; then
  printf 'offscreen_renderer=UNSUPPORTED_OR_FAILED status=%s\n' "$OFFSCREEN_STATUS"
fi
