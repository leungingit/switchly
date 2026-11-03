#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVIDENCE_ROOT="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-plugin-preview-t01.XXXXXX")"
BIN="$EVIDENCE_ROOT/T01Probe"
ARCH="$(uname -m)"

SOURCES=(
  "$ROOT/Models/AppSettings.swift"
  "$ROOT/Models/DockLayoutSpec.swift"
  "$ROOT/Models/Enums/GridBackground.swift"
  "$ROOT/Models/Enums/GridStyle.swift"
  "$ROOT/Models/Enums/NotificationStrategy.swift"
  "$ROOT/Models/Enums/PreviewHotspotEdge.swift"
  "$ROOT/Models/Enums/PreviewStrategy.swift"
  "$ROOT/Models/Enums/ShortcutPrefix.swift"
  "$ROOT/Models/Enums/ThumbnailSize.swift"
  "$ROOT/Models/MenuBarIcon.swift"
  "$ROOT/Models/MonitoredApp.swift"
  "$ROOT/Models/OnlineWeatherSettings.swift"
  "$ROOT/Models/UsageStatistics.swift"
  "$ROOT/Models/UsageStatisticsEfficiency.swift"
  "$ROOT/Models/Workspace.swift"
  "$ROOT/Models/Plugins/PluginGrant.swift"
  "$ROOT/Models/Plugins/PluginManifest.swift"
  "$ROOT/Models/Plugins/PluginScene.swift"
  "$ROOT/Models/Plugins/PluginUINode.swift"
  "$ROOT/Models/Plugins/SceneEvaluator.swift"
  "$ROOT/Services/Plugins/PluginRegistry.swift"
  "$ROOT/Services/Plugins/PluginPackageValidator.swift"
  "$ROOT/Utilities/AppLogger.swift"
  "$ROOT/Utilities/DesignTokens.swift"
  "$ROOT/Utilities/MotionTokens.swift"
  "$ROOT/Utilities/GlassEffect.swift"
  "$ROOT/Utilities/NativeCrystalContainer.swift"
  "$ROOT/Utilities/ThemeApplier.swift"
  "$ROOT/Views/PluginOverlayView.swift"
  "$ROOT/Views/PluginSceneView.swift"
  "$ROOT/Views/PluginSceneDrawing.swift"
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
"$BIN" plain --out "$EVIDENCE_ROOT/plain"
PLAIN_STATUS=$?
"$BIN" glass --out "$EVIDENCE_ROOT/glass"
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
