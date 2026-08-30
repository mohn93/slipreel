#!/usr/bin/env bash
# Test for stamp-build-date.sh. Run: bash scripts/stamp-build-date.test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
target="$root/packages/screen_recorder/lib/licensing/build_release_date.g.dart"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Preserve and restore the real file so the test never leaves it stamped to the
# test's date.
orig="$(cat "$target")"
restore() { printf '%s' "$orig" > "$target"; }
trap restore EXIT

# explicit date -> exact DateTime.utc line, leading zeros stripped (not octal)
"$here/stamp-build-date.sh" 2026-08-09 >/dev/null
grep -q 'final DateTime buildReleaseDate = DateTime.utc(2026, 8, 9);' "$target" \
  || fail "explicit date not stamped correctly:"$'\n'"$(cat "$target")"

# default (no arg) -> today's UTC date
today="$(date -u +%Y-%-m-%-d | tr '/' ' ')" # YYYY-M-D with no leading zeros
IFS=- read -r ty tm td <<<"$today"
"$here/stamp-build-date.sh" >/dev/null
grep -q "DateTime.utc($ty, $tm, $td);" "$target" \
  || fail "default date not today's UTC ($ty, $tm, $td):"$'\n'"$(cat "$target")"

# bad formats are rejected
if "$here/stamp-build-date.sh" "2026/08/09" >/dev/null 2>&1; then fail "accepted bad format 2026/08/09"; fi
if "$here/stamp-build-date.sh" "not-a-date" >/dev/null 2>&1; then fail "accepted 'not-a-date'"; fi
if "$here/stamp-build-date.sh" "2026-13-01" >/dev/null 2>&1; then fail "accepted month 13"; fi

echo "stamp-build-date.test.sh: OK"
