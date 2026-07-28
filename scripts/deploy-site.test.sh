#!/usr/bin/env bash
# Guards the two properties that matter, both about the shared webroot the
# release pipeline also writes to (appcast.xml, download/*.dmg):
#   1. a site deploy can never remove the release pipeline's artifacts;
#   2. a site deploy can never rewrite the webroot's ownership or mode, which
#      would strip the release user's ability to publish a new appcast.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/deploy-site.sh"
rc=0
fail() { echo "FAIL: $1" >&2; rc=1; }

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || fail "deploy-site.sh is not executable"

# Critical assertion 1: no destructive flag, in any of its spellings. `--del`
# is a documented alias for the same behavior and openrsync accepts it, so
# matching only the long form would miss it. NOTE: the pattern is applied to
# the whole file including comments, so deploy-site.sh's own documentation
# must describe these flags in prose rather than quoting them literally.
if grep -qE -- '(--delete|--del([^a-zA-Z]|$)|--remove-)' "$SCRIPT"; then
  fail "deploy-site.sh must never use a destructive rsync flag (shared webroot holds appcast.xml + download/)"
fi

# Critical assertion 2: content only — never ownership, group or mode. The
# SSH target may resolve to root, in which case -a (which implies -p -o -g)
# rewrites the shared webroot directory itself and locks the release user out
# of publishing appcast.xml. Checked against the executable body; the comments
# discuss -a by name on purpose.
BODY="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
for flag in '--no-perms' '--no-owner' '--no-group'; do
  grep -qF -- "$flag" <<<"$BODY" || fail "deploy-site.sh must pass $flag (shared webroot must keep its ownership)"
done
if grep -qE -- '(--archive|rsync[[:space:]]+-[[:alnum:]]*a)' <<<"$BODY"; then
  fail "deploy-site.sh must not use rsync -a/--archive (it preserves owner, group and mode)"
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
