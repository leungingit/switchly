#!/bin/sh
# 构建到系统临时目录，不自动启动或改变桌面。
set -eu
fixture_source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture_temp_root=${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}
fixture_build_dir=$(mktemp -d "${fixture_temp_root%/}/switchly-spaces-fixture.XXXXXX")
trap 'rm -rf "$fixture_build_dir"' 0
fixture_contents="$fixture_build_dir/SwitchlySpacesFixture.app/Contents"
mkdir -p "$fixture_contents/MacOS"
swiftc -parse-as-library "$fixture_source_dir/SpacesFixture.swift" -o "$fixture_contents/MacOS/Fixture"
cat > "$fixture_contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>com.switchly.spacesfixture</string>
<key>CFBundleName</key><string>SwitchlySpacesFixture</string>
</dict></plist>
PLIST
trap - 0
printf '%s\n' "$fixture_build_dir/SwitchlySpacesFixture.app"
