#!/usr/bin/env bash
# Stamp this build's release date into build_release_date.g.dart.
#
# The one-time export ceiling (spec §2/§4) compares this build's release date
# against the token's `updates_until`, so a RELEASE build must carry its real
# publish date — not the date the file was last hand-edited. Without this the
# baked date is frozen and the ceiling never bites: every future build claims
# the same old date, so a lapsed one-time license could still export on it.
#
# release-macos.sh calls this before `flutter build` so the compiled app carries
# the correct date. The checked-in value is just the date this build was cut.
#
# Usage: scripts/stamp-build-date.sh [YYYY-MM-DD]   (default: today, UTC)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/packages/screen_recorder/lib/licensing/build_release_date.g.dart"
DATE="${1:-$(date -u +%Y-%m-%d)}"

if [[ ! "$DATE" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
  echo "ERROR: bad date '$DATE' (need YYYY-MM-DD)" >&2
  exit 1
fi
# 10# forces base-10 so a leading zero (e.g. 08) is not parsed as octal.
Y=$((10#${BASH_REMATCH[1]}))
M=$((10#${BASH_REMATCH[2]}))
D=$((10#${BASH_REMATCH[3]}))
if (( M < 1 || M > 12 || D < 1 || D > 31 )); then
  echo "ERROR: '$DATE' is not a valid calendar date" >&2
  exit 1
fi

cat > "$OUT" <<EOF
// GENERATED at release time by scripts/stamp-build-date.sh — do not edit by
// hand for a release. The one-time export ceiling (spec §2/§4) compares this
// build's release date against the token's \`updates_until\`; the release
// pipeline overwrites this with the actual publish date. The checked-in value
// is the date this build was cut.
// A top-level \`const DateTime\` cannot call \`DateTime.utc(...)\` (not a const
// constructor), so this is exposed as \`final\` instead.
final DateTime buildReleaseDate = DateTime.utc($Y, $M, $D);
EOF

echo "stamped $OUT -> $Y-$(printf '%02d' "$M")-$(printf '%02d' "$D")"
