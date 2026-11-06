#!/usr/bin/env bash
# GitHub Pages 静态站（Website/）的本地构建、检查与发布辅助。用法：Scripts/pages.sh <build|check|enable|deploy>
set -euo pipefail
cd "$(dirname "$0")/.."

build() {
  rm -rf _site
  mkdir -p _site
  cp Website/*.html Website/style.css _site/
  cp -R Website/images _site/images
  cp docs/assets/images/desktop-grid-zh.svg _site/images/
  cp Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png _site/images/app-icon.png
  touch _site/.nojekyll
  echo "built _site: $(find _site -type f | wc -l | tr -d ' ') files"
}

check() {
  local bad=0 f ref
  cd _site
  for f in *.html; do
    for ref in $(grep -oE '(href|src)="[^"#:]+"' "$f" | sed -E 's/^[a-z]+="//; s/"$//'); do
      [ -e "$ref" ] || { echo "missing: $f -> $ref"; bad=1; }
    done
  done
  [ "$bad" = 0 ] && echo "links ok"
  return "$bad"
}

enable() {
  gh api -X POST 'repos/{owner}/{repo}/pages' -f build_type=workflow 2>/dev/null \
    || gh api -X PUT 'repos/{owner}/{repo}/pages' -f build_type=workflow
}

deploy() {
  gh workflow run pages.yml --ref main
  sleep 5
  gh run watch "$(gh run list --workflow pages.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
  gh api 'repos/{owner}/{repo}/pages' -q .html_url
}

case "${1:-}" in
  build|check|enable|deploy) "$1" ;;
  *) echo "usage: $0 <build|check|enable|deploy>" >&2; exit 2 ;;
esac
