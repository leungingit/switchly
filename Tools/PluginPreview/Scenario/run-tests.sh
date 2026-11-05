#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-preview-scenario.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_DIR"' EXIT
# PreviewMockWindows 复用 ThumbnailSize 与 WindowInfo；直编时补齐它们的编译闭包。
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Sources/Models/Plugins/PluginConsoleLine.swift" \
  "$ROOT/Sources/Models/Plugins/PluginGrant.swift" \
  "$ROOT/Sources/Models/Plugins/PluginManifest.swift" \
  "$ROOT/Sources/Services/Plugins/PluginRegistry.swift" \
  "$ROOT/Sources/Services/Plugins/PluginPackageValidator.swift" \
  "$ROOT/Sources/Services/Plugins/PluginStorage.swift" \
  "$ROOT/Sources/Utilities/AppLogger.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PreviewScenario.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/DefaultScenario.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PreviewScenarioExporter.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PluginPreviewInspect.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PluginPreviewStep.swift" \
  "$ROOT/Tools/PluginPreview/Entry/PreviewCommandLine.swift" \
  "$ROOT/Sources/Models/AppSettings.swift" \
  "$ROOT/Sources/Models/DockLayoutSpec.swift" \
  "$ROOT/Sources/Models/MenuBarIcon.swift" \
  "$ROOT/Sources/Models/MonitoredApp.swift" \
  "$ROOT/Sources/Models/OnlineWeatherSettings.swift" \
  "$ROOT/Sources/Models/UsageStatistics.swift" \
  "$ROOT/Sources/Models/UsageStatisticsEfficiency.swift" \
  "$ROOT/Sources/Models/Workspace.swift" \
  "$ROOT/Sources/Models/WindowInfo.swift" \
  "$ROOT/Sources/Models/Enums/GridBackground.swift" \
  "$ROOT/Sources/Models/Enums/GridStyle.swift" \
  "$ROOT/Sources/Models/Enums/NotificationStrategy.swift" \
  "$ROOT/Sources/Models/Enums/PreviewHotspotEdge.swift" \
  "$ROOT/Sources/Models/Enums/PreviewStrategy.swift" \
  "$ROOT/Sources/Models/Enums/ShortcutPrefix.swift" \
  "$ROOT/Sources/Models/Enums/ThumbnailSize.swift" \
  "$ROOT/Tools/PluginPreview/UI/PreviewLauncherLogic.swift" \
  "$ROOT/Tools/PluginPreview/UI/PreviewDebugModel.swift" \
  "$ROOT/Tools/PluginPreview/UI/PreviewDockHoverLogic.swift" \
  "$ROOT/Tools/PluginPreview/UI/PreviewDockLayout.swift" \
  "$ROOT/Tools/PluginPreview/UI/PreviewMockWindows.swift" \
  "$ROOT/Tests/PluginPreview/StepTests.swift" \
  "$ROOT/Tests/PluginPreview/ScenarioTests.swift" \
  "$ROOT/Tests/PluginPreview/DefaultScenarioTests.swift" \
  "$ROOT/Tests/PluginPreview/LauncherLogicTests.swift" \
  "$ROOT/Tests/PluginPreview/MockDockTests.swift" \
  "$ROOT/Tests/PluginPreview/DebugModelTests.swift" \
  -o "$TEST_DIR/scenario-tests"
"$TEST_DIR/scenario-tests"
