#!/usr/bin/env bash
# Generate/append a Sparkle appcast entry for a released DMG. Build-machine
# only (needs the `sparkle` CLI: brew install sparkle). EdDSA-signs the DMG and
# prepends a versioned <item> to appcast.xml (newest first), creating the
# channel skeleton on first run. Idempotent per version.
#
# Usage: update-appcast.sh <version> <build_number> <dmg> <enclosure_url> [appcast]
#   MINIMUM_SUPPORTED_BUILD=<integer>: require eligible older clients to update.
#   Omit to preserve policy; set 0 to disable. Must not exceed this release build.
#   Signing key: SPARKLE_ED_KEY_FILE=<file> (else the login-keychain key).
set -euo pipefail

VERSION="${1:?usage: update-appcast.sh <version> <build_number> <dmg> <url> [appcast]}"
BUILD="${2:?build_number required}"
DMG="${3:?dmg path required}"
URL="${4:?enclosure url required}"
APPCAST="${5:-dist/appcast.xml}"
MIN_OS="13.0"
FEED_TITLE="Slipreel"
FEED_LINK="https://slipreel.app/appcast.xml"

if [[ -n "${MINIMUM_SUPPORTED_BUILD+x}" ]]; then
  python3 - "$MINIMUM_SUPPORTED_BUILD" "$BUILD" <<'VALIDATE'
import re, sys
minimum, build = sys.argv[1:]
if not re.fullmatch(r"0|[1-9][0-9]*", minimum) or not build.isdecimal() or int(minimum) > int(build):
    sys.exit("ERROR: MINIMUM_SUPPORTED_BUILD must be a non-negative integer no greater than the release build")
VALIDATE
fi

command -v sign_update >/dev/null \
  || { echo "ERROR: sign_update not found: brew install sparkle (build-machine only)" >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "ERROR: DMG not found: $DMG" >&2; exit 1; }

# EdDSA-sign the DMG. sign_update prints:  sparkle:edSignature="..." length="..."
sign_args=()
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && sign_args=(-f "$SPARKLE_ED_KEY_FILE")
sig="$(sign_update ${sign_args[@]+"${sign_args[@]}"} "$DMG")" \
  || { echo "ERROR: sign_update failed (missing EdDSA key? see docs/release/SETUP.md)" >&2; exit 1; }
grep -q 'sparkle:edSignature=' <<<"$sig" \
  || { echo "ERROR: sign_update output missing edSignature: $sig" >&2; exit 1; }

pubdate="$(LC_ALL=C date -u +'%a, %d %b %Y %H:%M:%S +0000')"

# The <item> block. sig already carries the edSignature + length attributes.
item="    <item>
      <title>${FEED_TITLE} ${VERSION}</title>
      <pubDate>${pubdate}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>https://slipreel.app/changelog</sparkle:releaseNotesLink>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <enclosure url=\"${URL}\" ${sig} type=\"application/octet-stream\" />
    </item>"

mkdir -p "$(dirname "$APPCAST")"

if [[ ! -s "$APPCAST" ]] || ! grep -q '<!-- ITEMS -->' "$APPCAST"; then
  cat > "$APPCAST" <<SKEL
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${FEED_TITLE}</title>
    <link>${FEED_LINK}</link>
    <description>Slipreel updates</description>
    <language>en</language>
    <!-- ITEMS -->
  </channel>
</rss>
SKEL
fi

# Drop any existing <item> for this version (idempotent replace), then insert
# the fresh item right after the marker so newest is first.
tmp="$(mktemp)"
awk -v ver="$VERSION" '
  /<item>/ { buf=$0 ORS; inItem=1; hit=0; next }
  inItem {
    buf=buf $0 ORS
    if (index($0, "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>")) hit=1
    if ($0 ~ /<\/item>/) { if (!hit) printf "%s", buf; inItem=0; buf="" }
    next
  }
  { print }
' "$APPCAST" > "$tmp"

item_file="$(mktemp)"
printf '%s\n' "$item" > "$item_file"
awk -v itemfile="$item_file" '
  { print }
  /<!-- ITEMS -->/ {
    while ((getline line < itemfile) > 0) print line
    close(itemfile)
  }
' "$tmp" > "$APPCAST"
rm -f "$tmp" "$item_file"

# The channel policy is intentionally independent of individual releases.
# Ordinary releases retain it; only an explicit value changes or removes it.
if [[ -n "${MINIMUM_SUPPORTED_BUILD+x}" ]]; then
  python3 - "$APPCAST" "$MINIMUM_SUPPORTED_BUILD" <<'POLICY'
from pathlib import Path
import re, sys
import xml.etree.ElementTree as ET
path = Path(sys.argv[1])
source = path.read_text()
source = re.sub(r"\s*<slipreelMinimumSupportedBuild>[^<]*</slipreelMinimumSupportedBuild>", "", source)
if int(sys.argv[2]) > 0:
    source = source.replace("<channel>", "<channel>\n    <slipreelMinimumSupportedBuild>" + sys.argv[2] + "</slipreelMinimumSupportedBuild>", 1)
ET.fromstring(source)
path.write_text(source)
POLICY
fi

# Never deploy a broken feed: the output must be non-empty and contain the item
# we just wrote (guards against a truncated base file yielding an empty appcast).
[[ -s "$APPCAST" ]] && grep -q "<sparkle:version>${BUILD}</sparkle:version>" "$APPCAST" \
  || { echo "ERROR: update-appcast produced no valid item for $VERSION ($BUILD) in $APPCAST" >&2; exit 1; }

echo "update-appcast: wrote $VERSION ($BUILD) -> $APPCAST"
