#!/bin/bash
# Runs xcodebuild with the given arguments and fails when the build emitted any
# compiler or xcodebuild warning, so warnings cannot accumulate unnoticed.
# Host-environment noise (e.g. CoreSimulator version mismatch) is not matched:
# only `<file>:<line>:<col>: warning:` diagnostics and `xcodebuild: WARNING`.
set -o pipefail

LOG="$(mktemp -t switchly-xcodebuild)"
trap 'rm -f "$LOG"' EXIT

xcodebuild "$@" 2>&1 | tee "$LOG"
STATUS=$?
[ "$STATUS" -eq 0 ] || exit "$STATUS"

WARNINGS="$(grep -E ': warning: |^warning: |xcodebuild: WARNING' "$LOG" | sort -u)"
if [ -n "$WARNINGS" ]; then
  printf '\n\033[0;31m❌ Build produced warnings (warnings are treated as errors):\033[0m\n%s\n' "$WARNINGS" >&2
  exit 1
fi
