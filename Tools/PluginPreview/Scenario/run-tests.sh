#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}/switchly-preview-scenario.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Tools/PluginPreview/Scenario/PreviewScenario.swift" \
  "$ROOT/Tests/PluginPreview/ScenarioTests.swift" \
  -o "$TEST_DIR/scenario-tests"
"$TEST_DIR/scenario-tests"
