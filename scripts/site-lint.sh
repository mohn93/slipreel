#!/usr/bin/env bash
# Enforces the landing page's global constraints:
#   1. no third-party network requests
#   2. every referenced local asset exists
#   3. the stylesheet honors prefers-reduced-motion
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${SITE_DIR:-$ROOT/site}"
rc=0
violation() { echo "site-lint: $1" >&2; rc=1; }

[[ -d "$SITE" ]] || { echo "site-lint: no such dir: $SITE" >&2; exit 1; }

# 1. External hosts. Namespace URIs in XML/JSON-LD are declarations, not
#    requests, so a small allowlist is permitted. First-party subdomains of
#    slipreel.app (e.g. api.slipreel.app) are ours. Test files hold fixture
#    URLs that never ship, so they are excluded from the scan entirely.
allow='([a-z0-9-]+\.)*slipreel\.app|schema\.org|www\.w3\.org|purl\.org|andymatuschak\.org'
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  grep -qE "^https?://($allow)" <<<"$url" || violation "external request: $url"
done < <(grep -rhoE 'https?://[A-Za-z0-9.:-]+' \
           --include='*.html' --include='*.css' --include='*.js' \
           --exclude='*.test.js' \
           "$SITE" 2>/dev/null | sort -u)

# 2. Local assets referenced from HTML must exist on disk. References resolve
#    the way the production nginx serves them (try_files $uri $uri.html $uri/):
#    a root-relative clean URL like /loom-alternative is backed by
#    loom-alternative.html, and / is backed by index.html.
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  case "$ref" in http*|//*|\#*|mailto:*|data:*) continue ;; esac
  path="${ref%%\#*}"; path="${path%%\?*}"
  [[ -z "$path" ]] && continue
  rel="${path#/}"
  if [[ -z "$rel" ]]; then
    [[ -f "$SITE/index.html" ]] || violation "missing local asset: $path"
  elif [[ -f "$SITE/$rel" || -f "$SITE/$rel.html" || -f "$SITE/$rel/index.html" ]]; then
    :
  else
    violation "missing local asset: $path"
  fi
done < <(grep -rhoE '(src|href)="[^"]+"' --include='*.html' "$SITE" 2>/dev/null \
           | sed -E 's/^(src|href)="//; s/"$//' | sort -u)

# 3. Reduced motion.
for css in "$SITE"/assets/css/*.css; do
  [[ -f "$css" ]] || continue
  grep -q 'prefers-reduced-motion' "$css" \
    || violation "no prefers-reduced-motion block in $(basename "$css")"
done

[[ $rc -eq 0 ]] && echo "site-lint: clean"
exit $rc
