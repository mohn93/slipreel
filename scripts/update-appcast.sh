#!/usr/bin/env bash
# Generate/append a Sparkle appcast entry for a released DMG. Build-machine
# only (needs the `sparkle` CLI: brew install sparkle). EdDSA-signs the DMG and
# prepends a versioned <item> to appcast.xml (newest first), creating the
# channel skeleton on first run. Idempotent per version.
#
# Usage: update-appcast.sh <version> <build_number> <dmg> <enclosure_url> [appcast]
#   Signing key: SPARKLE_ED_KEY_FILE=<file> (else the login-keychain key).
set -euo pipefail

VERSION="${1:?usage: update-appcast.sh <version> <build_number> <dmg> <url> [appcast]}"
BUILD="${2:?build_number required}"
DMG="${3:?dmg path required}"
URL="${4:?enclosure url required}"
APPCAST="${5:-dist/appcast.xml}"
MIN_OS="13.0"
FEED_TITLE="Slipreel"
FEED_LINK="https://mohn93.github.io/slipreel/appcast.xml"

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

# Never deploy a broken feed: the output must be non-empty and contain the item
# we just wrote (guards against a truncated base file yielding an empty appcast).
[[ -s "$APPCAST" ]] && grep -q "<sparkle:version>${BUILD}</sparkle:version>" "$APPCAST" \
  || { echo "ERROR: update-appcast produced no valid item for $VERSION ($BUILD) in $APPCAST" >&2; exit 1; }

echo "update-appcast: wrote $VERSION ($BUILD) -> $APPCAST"
