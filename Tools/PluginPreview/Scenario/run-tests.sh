#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-preview-scenario.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_DIR"' EXIT
# PreviewMockWindows 复用 ThumbnailSize 与 WindowInfo；直编时补齐它们的编译闭包。
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Models/Plugins/PluginConsoleLine.swift" \
  "$ROOT/Models/Plugins/PluginGrant.swift" \
  "$ROOT/Models/Plugins/PluginManifest.swift" \
  "$ROOT/Services/Plugins/PluginRegistry.swift" \
  "$ROOT/Services/Plugins/PluginPackageValidator.swift" \
  "$ROOT/Services/Plugins/PluginStorage.swift" \
  "$ROOT/Utilities/AppLogger.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PreviewScenario.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/DefaultScenario.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PreviewScenarioExporter.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PluginPreviewInspect.swift" \
  "$ROOT/Tools/PluginPreview/Scenario/PluginPreviewStep.swift" \
  "$ROOT/Tools/PluginPreview/Entry/PreviewCommandLine.swift" \
  "$ROOT/Models/AppSettings.swift" \
  "$ROOT/Models/DockLayoutSpec.swift" \
  "$ROOT/Models/MenuBarIcon.swift" \
  "$ROOT/Models/MonitoredApp.swift" \
  "$ROOT/Models/OnlineWeatherSettings.swift" \
  "$ROOT/Models/UsageStatistics.swift" \
  "$ROOT/Models/UsageStatisticsEfficiency.swift" \
  "$ROOT/Models/Workspace.swift" \
  "$ROOT/Models/WindowInfo.swift" \
  "$ROOT/Models/Enums/GridBackground.swift" \
  "$ROOT/Models/Enums/GridStyle.swift" \
  "$ROOT/Models/Enums/NotificationStrategy.swift" \
  "$ROOT/Models/Enums/PreviewHotspotEdge.swift" \
  "$ROOT/Models/Enums/PreviewStrategy.swift" \
  "$ROOT/Models/Enums/ShortcutPrefix.swift" \
  "$ROOT/Models/Enums/ThumbnailSize.swift" \
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
