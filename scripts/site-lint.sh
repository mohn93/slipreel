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
#    requests, so a small allowlist is permitted.
allow='slipreel\.app|schema\.org|www\.w3\.org|purl\.org|andymatuschak\.org'
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  grep -qE "^https?://($allow)" <<<"$url" || violation "external request: $url"
done < <(grep -rhoE 'https?://[A-Za-z0-9.:-]+' \
           --include='*.html' --include='*.css' --include='*.js' \
           "$SITE" 2>/dev/null | grep -v '\.test\.js' | sort -u)

# 2. Local assets referenced from HTML must exist on disk.
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  case "$ref" in http*|//*|\#*|mailto:*|data:*) continue ;; esac
  path="${ref%%\#*}"; path="${path%%\?*}"
  [[ -z "$path" ]] && continue
  [[ -f "$SITE/$path" ]] || violation "missing local asset: $path"
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
