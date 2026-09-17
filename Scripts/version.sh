#!/usr/bin/env bash
#
# version.sh — the single implementation behind `make version`, `make bump-*`
# and `make release-*`.
#
#   Scripts/version.sh show
#   Scripts/version.sh bump    <patch|minor|major|build>
#   Scripts/version.sh release <patch|minor|major> [--allow-empty] [--dry-run]
#
# Resources/Info.plist is the single source of truth: CFBundleShortVersionString
# is the marketing version, CFBundleVersion the build number.
#
#   bump-*     change the numbers only. Nothing is committed — this is the
#              "I just need the version to move" path.
#   release-*  are atomic: validate the tree, promote the CHANGELOG's
#              [Unreleased] section into a dated version section, bump the
#              plist, commit, and tag vX.Y.Z — all or nothing.
#
# Neither command pushes. `git push origin main --tags` hands the tag to
# .github/workflows/release.yml, which builds, packages and publishes.

set -euo pipefail

cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
CHANGELOG="CHANGELOG.md"

# PlistBuddy (like plutil) re-serialises a plist with its keys sorted, so
# Resources/Info.plist is kept in that canonical, alphabetical order: a bump
# is then a one-line diff instead of an unrelated reshuffle of every key.
# Add new keys in sorted position.

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

die()  { printf '%s❌ %s%s\n' "$RED" "$1" "$NC" >&2; exit 1; }
ok()   { printf '%s✅ %s%s\n' "$GREEN" "$1" "$NC"; }
note() { printf '%sℹ️  %s%s\n' "$BLUE" "$1" "$NC"; }
warn() { printf '%s⚠️  %s%s\n' "$YELLOW" "$1" "$NC" >&2; }

usage() {
  cat <<'EOF'
usage: Scripts/version.sh <command> [options]

  show                     print "vX.Y.Z (build N)"
  bump   <part>            patch | minor | major | build  (edits Info.plist only)
  release <part>           patch | minor | major         (bump + CHANGELOG + commit + tag)

release options:
  --allow-empty            release even when [Unreleased] has no entries
  --dry-run                run every check, change nothing
EOF
}

read_marketing() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST"; }
read_build()     { /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST"; }

# A plain X.Y.Z. Pre-release and build-metadata suffixes are rejected rather
# than silently dropped: splitting "1.2.3-beta.1" on "." and doing arithmetic on
# the third field would quietly yield 1.2.4.
is_semver() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

bumped() { # <version> <part> -> new version on stdout
  local v="$1" part="$2" major minor patch
  IFS='.' read -r major minor patch <<<"$v"
  case "$part" in
    major) printf '%s.0.0' "$((major + 1))" ;;
    minor) printf '%s.%s.0' "$major" "$((minor + 1))" ;;
    patch) printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))" ;;
    *) die "unknown version part '$part' (expected patch, minor or major)" ;;
  esac
}

# Non-blank lines between "## [Unreleased]" and the next "## " heading.
unreleased_entries() {
  awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## / { exit }
    inside && /[^[:space:]]/ { n++ }
    END { print n + 0 }
  ' "$CHANGELOG"
}

# The [Unreleased] heading stays (as the home for the next cycle); its entries
# move under the new, dated version heading.
promote_changelog() { # <new-version>
  local ver="$1" today tmp
  today="$(date +%Y-%m-%d)"
  tmp="$(mktemp)"
  awk -v ver="$ver" -v today="$today" '
    !done && /^## \[Unreleased\]/ {
      print "## [Unreleased]"
      print ""
      print "## [" ver "] - " today
      done = 1
      next
    }
    { print }
  ' "$CHANGELOG" > "$tmp"
  mv "$tmp" "$CHANGELOG"
}

# Keep the link refs at the bottom of the file pointing at the new version.
promote_links() { # <new-version>
  local ver="$1" url base tmp
  if ! grep -q '^\[Unreleased\]: ' "$CHANGELOG"; then
    warn "no '[Unreleased]:' link line in $CHANGELOG — add the v$ver link by hand"
    return 0
  fi
  url="$(awk '/^\[Unreleased\]: / { print $2; exit }' "$CHANGELOG")"
  case "$url" in
    */compare/*) base="${url%%/compare/*}" ;;
    *) warn "cannot derive the repository URL from the '[Unreleased]:' line — add the v$ver link by hand"
       return 0 ;;
  esac
  tmp="$(mktemp)"
  awk -v ver="$ver" -v base="$base" '
    /^\[Unreleased\]: / {
      print "[Unreleased]: " base "/compare/v" ver "...HEAD"
      print "[" ver "]: " base "/releases/tag/v" ver
      next
    }
    { print }
  ' "$CHANGELOG" > "$tmp"
  mv "$tmp" "$CHANGELOG"
}

cmd_show() {
  printf 'v%s (build %s)\n' "$(read_marketing)" "$(read_build)"
}

cmd_bump() { # <patch|minor|major|build>
  local part="${1:-}"
  case "$part" in
    patch|minor|major|build) ;;
    *) die "usage: version.sh bump <patch|minor|major|build>" ;;
  esac

  if [ "$part" = "build" ]; then
    local build next
    build="$(read_build)"
    next="$((build + 1))"
    /usr/libexec/PlistBuddy -c "Set CFBundleVersion $next" "$PLIST"
    ok "Build: $build → $next"
    return 0
  fi

  local current new
  current="$(read_marketing)"
  is_semver "$current" || die "CFBundleShortVersionString is '$current', not a plain X.Y.Z version — fix $PLIST by hand before bumping"
  new="$(bumped "$current" "$part")"
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $new" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion 1" "$PLIST"
  ok "Version: $current → $new (build reset to 1)"
}

cmd_release() { # <patch|minor|major> [--allow-empty] [--dry-run]
  local part="${1:-}"
  shift || true
  local allow_empty=0 dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-empty) allow_empty=1 ;;
      --dry-run)     dry_run=1 ;;
      *) die "unknown flag '$1' (usage: version.sh release <patch|minor|major> [--allow-empty] [--dry-run])" ;;
    esac
    shift
  done
  case "$part" in
    patch|minor|major) ;;
    *) die "usage: version.sh release <patch|minor|major>" ;;
  esac

  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

  local current new tag entries
  current="$(read_marketing)"
  is_semver "$current" || die "CFBundleShortVersionString is '$current', not a plain X.Y.Z version — fix $PLIST by hand before releasing"
  new="$(bumped "$current" "$part")"
  tag="v$new"

  # A release commit must contain the release, and nothing else. Untracked
  # files count as dirt: `git diff` alone would happily tag a commit that is
  # missing files the working tree still has, publishing a tree without them.
  if ! git diff --quiet || ! git diff --cached --quiet \
     || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    die "working tree has uncommitted changes (including untracked files) — commit or stash them first"
  fi

  # A version is released once.
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists — choose another version, or delete the tag if it was a mistake"
  fi

  # The CHANGELOG has to describe what is being shipped.
  [ -f "$CHANGELOG" ] || die "$CHANGELOG is missing"
  grep -q '^## \[Unreleased\]' "$CHANGELOG" || die "$CHANGELOG has no '## [Unreleased]' section"
  entries="$(unreleased_entries)"
  if [ "$entries" -eq 0 ] && [ "$allow_empty" -eq 0 ]; then
    die "$CHANGELOG's [Unreleased] section is empty — write down what changed, or pass --allow-empty"
  fi

  note "Releasing $current → $new ($entries line(s) under [Unreleased])"

  if [ "$dry_run" -eq 1 ]; then
    note "--dry-run: nothing was changed, committed or tagged."
    return 0
  fi

  promote_changelog "$new"
  promote_links "$new"
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $new" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion 1" "$PLIST"

  # Same pre-flight CI runs, now strict about the CHANGELOG section we just
  # wrote. Failing here leaves the tree modified but uncommitted, hence the hint.
  if [ "${SKIP_VERIFY:-0}" != "1" ]; then
    if ! ./verify.sh --release; then
      die "pre-flight checks failed — nothing was committed. Undo with: git checkout -- $PLIST $CHANGELOG"
    fi
  fi

  git add "$PLIST" "$CHANGELOG"
  git commit -q -m "chore: release $new"
  git tag -a "$tag" -m "$tag"

  ok "Released $tag at commit $(git rev-parse --short HEAD)."
  printf '\n%sNext:%s\n' "$BLUE" "$NC"
  printf '  git push origin %s --tags\n' "$(git rev-parse --abbrev-ref HEAD)"
  printf '  → .github/workflows/release.yml builds, packages and publishes the GitHub Release.\n'
}

command="${1:-}"
shift || true
case "$command" in
  show)    cmd_show ;;
  bump)    cmd_bump "$@" ;;
  release) cmd_release "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$command' (expected show, bump or release; try --help)" ;;
esac
