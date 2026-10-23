#!/usr/bin/env bash
# R2b driver (research only). Run from a terminal that already holds Accessibility + Input Monitoring; the probe executable is started
# directly (never through `open`) so the terminal is the TCC responsible process. Temporarily enables the system "Switch to Desktop 1-9"
# hotkeys (symbolic hotkeys 118-126, defaults Control+1..9), runs the probe serially, and ALWAYS restores the preferences afterwards
# (trap on EXIT/INT/TERM/HUP), then reads 118-126 back and compares them with the original values. mru-spaces is never touched.
# Usage: run-r2b.sh <probe_root>   (probe_root: build directory containing ClosedLoopProbe.app)
set -u
root="${1:?probe root}"
probe="$root/ClosedLoopProbe.app/Contents/MacOS/ClosedLoopProbe"
activate=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings
backup="$root/hotkeys-backup"; mkdir -p "$backup"
domain=com.apple.symbolichotkeys
restored=0

hotkey_state() { # prints canonical JSON of hotkeys 118-126 from the live preferences
  defaults export "$domain" - | python3 -I -c '
import json,plistlib,sys
d=plistlib.loads(sys.stdin.buffer.read()).get("AppleSymbolicHotKeys",{})
print(json.dumps({str(k):d.get(str(k)) for k in range(118,127)},sort_keys=True))'
}

restore() {
  [ "$restored" = 1 ] && return; restored=1
  pkill -f 'ClosedLoopProbe --fixture' 2>/dev/null
  defaults import "$domain" "$backup/symbolichotkeys-export.plist"
  "$activate" -u >/dev/null 2>&1
  sleep 1
  after="$(hotkey_state)"
  printf '%s\n' "$after" > "$root/hotkeys-after.json"
  if [ "$after" = "$(cat "$root/hotkeys-before.json")" ]; then echo "HOTKEYS_RESTORED_VERIFIED=yes"; else echo "HOTKEYS_RESTORED_VERIFIED=NO (mismatch, see hotkeys-before/after.json)"; fi
}
trap restore EXIT INT TERM HUP

cp "$HOME/Library/Preferences/$domain.plist" "$backup/$domain.plist" || exit 3
defaults export "$domain" "$backup/symbolichotkeys-export.plist" || exit 3
hotkey_state > "$root/hotkeys-before.json"

# Control+digit key codes (ANSI): 1..9
codes=(18 19 20 21 23 22 26 28 25)
for n in 1 2 3 4 5 6 7 8 9; do
  id=$((117+n)); code=${codes[$((n-1))]}
  defaults write "$domain" AppleSymbolicHotKeys -dict-add "$id" \
    "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>65535</integer><integer>$code</integer><integer>262144</integer></array><key>type</key><string>standard</string></dict></dict>" || exit 4
done
"$activate" -u >/dev/null 2>&1
sleep 1
hotkey_state > "$root/hotkeys-enabled.json"

start=$(date +%s)
# Run 1: the display with the empty desktop (display index 0). Run 2: three-Space display, origin moved to an end Space so a non-adjacent target exists.
# R2B_RUNS selects runs ("1 2" by default), R2B_TAG suffixes the output names; R2_SCENARIOS / R2_PATHS are passed through to the probe.
for run in ${R2B_RUNS:-1 2}; do
  if [ "$run" = 1 ]; then idx=0; origin=""; budget=70; else idx=1; origin="${R2B_RUN2_ORIGIN:-46}"; budget=80; fi
  R2_HOTKEYS_ENABLED=1 R2_DISPLAY_INDEX=$idx R2_ORIGIN_SPACE="$origin" R2_MAX_ATTEMPTS=1 R2_BUDGET=$budget "$probe" --out "$root/r2b-run$run${R2B_TAG:-}.json" 2> "$root/run$run${R2B_TAG:-}.err"
  echo "run$run exit=$?"
done
echo "elapsed_seconds=$(( $(date +%s) - start ))"
