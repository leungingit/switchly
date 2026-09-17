#!/usr/bin/env bash
#
# verify.sh — pre-flight check for Switchly.
#
# Verifies the toolchain, the project layout, and — most importantly — that the
# tree is safe to publish: no committed build artifacts, credentials, or
# personal data.
#
# Run it before opening a pull request or cutting a release:
#
#   ./verify.sh              pre-flight for a change / pull request
#   ./verify.sh --release    stricter: a missing CHANGELOG section for the
#                            current version is a failure, not a warning.
#                            Used by `make release-*` and by the release
#                            workflow, where the version becomes public.
#
# Exit status: 0 if every required check passed, 1 if a check failed,
#              2 on a usage error.

set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"

# Homebrew's bin directory is missing from PATH when this script is launched from
# a GUI app, an IDE, or any non-login shell — which makes the toolchain checks
# below report false "not found" warnings. Append rather than prepend so that
# system tools keep precedence.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

FAILURES=0
WARNINGS=0

RELEASE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE_MODE=1 ;;
    -h|--help)
      printf 'usage: %s [--release]\n' "$0"
      printf '  --release  fail (instead of warn) when CHANGELOG.md has no section for the current version\n'
      exit 0 ;;
    *)
      printf 'verify.sh: unknown argument: %s\n' "$arg" >&2
      exit 2 ;;
  esac
done

section() { printf '\n%s%s%s\n' "$BLUE" "$1" "$NC"; }
pass()    { printf '  %s✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn()    { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$1"; WARNINGS=$((WARNINGS + 1)); }
fail()    { printf '  %s✗%s %s\n' "$RED" "$NC" "$1"; FAILURES=$((FAILURES + 1)); }

printf '%sSwitchly — pre-flight check%s\n' "$BLUE" "$NC"
printf 'repository: %s\n' "$ROOT"

# ─────────────────────────────────────────────────────────────────────────────
section "1. Toolchain"
# ─────────────────────────────────────────────────────────────────────────────

if [ "$(uname -s)" = "Darwin" ]; then
  pass "macOS $(sw_vers -productVersion) ($(uname -m))"
else
  fail "not running on macOS — this project builds macOS apps only"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  pass "$(xcodebuild -version 2>/dev/null | head -1)"
else
  fail "xcodebuild not found — install Xcode from the App Store"
fi

if command -v swift >/dev/null 2>&1; then
  pass "$(swift --version 2>/dev/null | head -1)"
else
  warn "swift toolchain not on PATH"
fi

if command -v xcodegen >/dev/null 2>&1; then
  pass "xcodegen present"
else
  warn "xcodegen not found — 'brew install xcodegen' (needed by 'make bootstrap')"
fi

if command -v gh >/dev/null 2>&1; then
  pass "gh CLI available (used by 'make github-release')"
else
  warn "gh CLI not found — 'brew install gh' (only needed for releases)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "2. Project layout"
# ─────────────────────────────────────────────────────────────────────────────

for dir in App Models ViewModels Views Services Utilities Resources Supporting Tests Scripts; do
  if [ -d "$dir" ]; then
    pass "$dir/"
  else
    fail "$dir/ is missing"
  fi
done

required=(
  project.yml
  Makefile
  Resources/Info.plist
  Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
  Supporting/Switchly.entitlements
  App/SwitchlyApp.swift
  App/AppDelegate.swift
  Services/AccessibilityService.swift
  Services/WindowSwitchService.swift
  Utilities/WindowMatchRules.swift
  Tests/UnitTests/WindowMatchRulesTests.swift
  Switchly.xcodeproj/project.pbxproj
  Switchly.xcodeproj/xcshareddata/xcschemes/Switchly.xcscheme
  README.md
  LICENSE
  PRIVACY_POLICY.md
  CONTRIBUTING.md
  SECURITY.md
  CODE_OF_CONDUCT.md
  CHANGELOG.md
)
for file in "${required[@]}"; do
  if [ -f "$file" ]; then
    pass "$file"
  else
    fail "$file is missing"
  fi
done

for file in .github/workflows/ci.yml .github/workflows/release.yml .github/dependabot.yml; do
  if [ -f "$file" ]; then
    pass "$file"
  else
    fail "$file is missing"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "3. Version consistency"
# ─────────────────────────────────────────────────────────────────────────────

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist 2>/dev/null || true)"
if [ -n "$VERSION" ] && [ -n "$BUILD" ]; then
  pass "Info.plist version: $VERSION (build $BUILD)"
else
  fail "could not read CFBundleShortVersionString / CFBundleVersion from Resources/Info.plist"
fi

if grep -q "## \[$VERSION\]" CHANGELOG.md 2>/dev/null; then
  pass "CHANGELOG.md has a section for $VERSION"
elif [ "$RELEASE_MODE" -eq 1 ]; then
  fail "CHANGELOG.md has no '## [$VERSION]' section — add it before releasing"
else
  warn "CHANGELOG.md has no '## [$VERSION]' section"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "4. Nothing published by accident  (the important part)"
# ─────────────────────────────────────────────────────────────────────────────

if git rev-parse --git-dir >/dev/null 2>&1; then

  # 4a. Build artifacts must not be tracked.
  bad_paths="$(git ls-files | grep -E '^(build|DerivedData)/|\.app/|\.dSYM/|\.zip$|\.dmg$|\.xcarchive/' || true)"
  if [ -z "$bad_paths" ]; then
    pass "no build artifacts tracked by git"
  else
    fail "build artifacts are tracked by git:"
    printf '      %s\n' $bad_paths
  fi

  # 4b. Credentials must not be tracked. `git ls-files` keeps untracked local
  #     files from raising false alarms.
  cred_pattern='\.(pem|key|p12|pfx|cer|crt|mobileprovision|provisionprofile)$|(^|/)\.env($|\.)|(^|/)Credentials/|(^|/)secrets/'
  bad_creds="$(git ls-files | grep -Ei "$cred_pattern" || true)"
  if [ -z "$bad_creds" ]; then
    pass "no credentials, certificates, or .env files tracked"
  else
    fail "credential-like files are tracked by git:"
    printf '      %s\n' $bad_creds
  fi

  # 4c. Personal / machine-specific data must not appear in tracked text files.
  #     High-signal patterns only, to keep this check free of false positives:
  #       - a real signing identity, i.e. "Apple Development: Jane Doe (AB12CD34EF)"
  #         (the documented placeholder "Apple Development: Your Name (TEAMID)"
  #         does not match, because a Team ID is exactly 10 characters)
  #       - absolute home paths, personal mail domains, cloud/API keys
  #     verify.sh itself is skipped: it necessarily contains the pattern text.
  #
  #     The project publishes exactly one contact address on purpose: it is
  #     named in PRIVACY_POLICY.md, SECURITY.md and CODE_OF_CONDUCT.md. It
  #     matches the personal-mail heuristic above, so any line that carries
  #     exactly that address is dropped from the results. Every other address,
  #     including a second one on the same line, still fails the check.
  public_contact='liangkaijun52013@gmail.com'
  leak_pattern='Apple Development: [^()]*\([A-Z0-9]{10}\)|/Users/[a-z][a-zA-Z0-9_.-]*/|@gmail\.com|@qq\.com|@163\.com|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY'
  leaks="$(git ls-files '*.swift' '*.md' '*.sh' '*.yml' '*.yaml' '*.json' '*.plist' '*.strings' '*.entitlements' 'Makefile' 2>/dev/null \
    | grep -v '^verify\.sh$' \
    | xargs grep -nEI "$leak_pattern" 2>/dev/null \
    | grep -vF "$public_contact" || true)"
  if [ -z "$leaks" ]; then
    pass "no personal identifiers, home paths, or API keys in tracked files"
  else
    fail "possible personal data / secrets in tracked files:"
    printf '      %s\n' "$leaks"
  fi

  # 4d. Files that should stay local.
  for local_only in .DS_Store .vscode/launch.json .claude/settings.local.json .workbuddy/memory/MEMORY.md; do
    [ -e "$local_only" ] || continue
    if git check-ignore -q "$local_only"; then
      pass "$local_only is git-ignored"
    else
      warn "$local_only exists and is NOT git-ignored"
    fi
  done

  # 4e. Report the working tree state, so this is not mistaken for a clean bill.
  dirty="$(git status --porcelain | wc -l | tr -d ' ')"
  if [ "$dirty" -gt 0 ]; then
    warn "$dirty path(s) have uncommitted changes — review 'git status' before tagging"
  else
    pass "working tree is clean"
  fi

else
  warn "not a git repository — skipped the publication checks"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "5. Code hygiene"
# ─────────────────────────────────────────────────────────────────────────────

swift_count="$(find App Models ViewModels Views Services Utilities Tests Scripts -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')"
pass "$swift_count Swift files"

oversized="$(find App Models ViewModels Views Services Utilities -name '*.swift' -exec wc -l {} + 2>/dev/null \
  | awk '$1 > 500 && $2 != "total" { print "      " $2 " (" $1 " lines)" }')"
if [ -z "$oversized" ]; then
  pass "all source files are within the 500-line guideline"
else
  warn "files over 500 lines (split them when you touch them):"
  printf '%s\n' "$oversized"
fi

todo_count="$(grep -rcE '\b(TODO|FIXME|XXX)\b' App Models ViewModels Views Services Utilities --include='*.swift' 2>/dev/null \
  | awk -F: '{ s += $2 } END { print s + 0 }')"
if [ "$todo_count" -eq 0 ]; then
  pass "no TODO / FIXME markers in source"
else
  warn "$todo_count TODO / FIXME marker(s) in source"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s──────────────────────────────────────────%s\n' "$BLUE" "$NC"
if [ "$FAILURES" -eq 0 ]; then
  printf '%s  PASS%s  %d check(s) failed, %d warning(s)\n' "$GREEN" "$NC" "$FAILURES" "$WARNINGS"
  printf '  Next: make bootstrap && make build && make test-unit\n\n'
  exit 0
else
  printf '%s  FAIL%s  %d check(s) failed, %d warning(s)\n\n' "$RED" "$NC" "$FAILURES" "$WARNINGS"
  exit 1
fi
