#!/usr/bin/env bash
set -euo pipefail

fixture_sources="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# GRID_PROBE_BUILD_ROOT lets a run choose a system-temp build directory (for example $TMPDIR/desktop-grid-r2).
if [ -n "${GRID_PROBE_BUILD_ROOT:-}" ]; then
  probe_root="$GRID_PROBE_BUILD_ROOT"
  mkdir -p "$probe_root"
else
  probe_root="$(mktemp -d /tmp/switchly-grid-control.XXXXXX)"
fi

mkdir -p "$probe_root/GridProbe.app/Contents/MacOS"
mkdir -p "$probe_root/ForeignFixture.app/Contents/MacOS"
mkdir -p "$probe_root/ClosedLoopProbe.app/Contents/MacOS"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -framework AppKit -framework ApplicationServices \
  "$fixture_sources/space-control-probe.m" \
  -o "$probe_root/GridProbe.app/Contents/MacOS/GridProbe"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
  "$fixture_sources/foreign-fixture.m" \
  -o "$probe_root/ForeignFixture.app/Contents/MacOS/ForeignFixture"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -framework AppKit -framework ApplicationServices \
  "$fixture_sources/switch-closed-loop-probe.m" \
  -o "$probe_root/ClosedLoopProbe.app/Contents/MacOS/ClosedLoopProbe"

python3 - "$probe_root" <<'PY'
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1])
for name in ("GridProbe", "ForeignFixture", "ClosedLoopProbe"):
    info = {
        "CFBundleIdentifier": f"com.switchly.research.{name}",
        "CFBundleExecutable": name,
        "CFBundleName": name,
        "CFBundlePackageType": "APPL",
    }
    with (root / f"{name}.app/Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
PY

# Build only. Launching and every system operation remain explicit test steps.
printf '%s\n' "$probe_root"
