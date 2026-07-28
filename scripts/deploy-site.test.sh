#!/usr/bin/env bash
# Guards the one property that matters: a site deploy can never remove the
# release pipeline's artifacts (appcast.xml, download/*.dmg) from the shared
# webroot.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/deploy-site.sh"
rc=0
fail() { echo "FAIL: $1" >&2; rc=1; }

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || fail "deploy-site.sh is not executable"

# The critical assertion.
if grep -qE -- '--delete' "$SCRIPT"; then
  fail "deploy-site.sh must never use --delete (shared webroot holds appcast.xml + download/)"
fi

# Dev-only files must not be published.
for pat in 'package.json' '\*.test.js'; do
  grep -qE -- "--exclude[ =]'?$pat" "$SCRIPT" || fail "deploy-site.sh must exclude $pat"
done

# Refuses to deploy an empty/missing site dir instead of silently succeeding.
tmp="$(mktemp -d)"
if SITE_DIR="$tmp" DEPLOY_TARGET="invalid.invalid" "$SCRIPT" >/dev/null 2>&1; then
  fail "deploy-site.sh should exit non-zero when index.html is missing"
fi
rmdir "$tmp"

[[ $rc -eq 0 ]] && echo "deploy-site.test: all checks passed"
exit $rc
