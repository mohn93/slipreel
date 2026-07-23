#!/usr/bin/env bash
# Test for update-appcast.sh using a fake sign_update. Run: bash scripts/update-appcast.test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake sign_update on PATH: prints a canned Sparkle signature line.
cat > "$tmp/sign_update" <<'FAKE'
#!/usr/bin/env bash
echo 'sparkle:edSignature="FAKESIG==" length="42"'
FAKE
chmod +x "$tmp/sign_update"
export PATH="$tmp:$PATH"

appcast="$tmp/appcast.xml"
touch "$tmp/Slipreel-1.0.0.dmg" "$tmp/Slipreel-1.0.1.dmg"

# first release creates the skeleton and the 1.0.0 item
"$here/update-appcast.sh" 1.0.0 1000000 "$tmp/Slipreel-1.0.0.dmg" \
  "https://example.com/Slipreel-1.0.0.dmg" "$appcast"
grep -q '<sparkle:version>1000000</sparkle:version>' "$appcast" || fail "missing 1.0.0 version"
grep -q 'sparkle:edSignature="FAKESIG=="' "$appcast" || fail "missing signature"
grep -q 'url="https://example.com/Slipreel-1.0.0.dmg"' "$appcast" || fail "missing enclosure url"

# second release prepends 1.0.1 and keeps 1.0.0
"$here/update-appcast.sh" 1.0.1 1000001 "$tmp/Slipreel-1.0.1.dmg" \
  "https://example.com/Slipreel-1.0.1.dmg" "$appcast"
grep -q '<sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>' "$appcast" || fail "dropped 1.0.0"
grep -q '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>' "$appcast" || fail "missing 1.0.1"
first="$(grep -n 'shortVersionString' "$appcast" | head -1)"
[[ "$first" == *1.0.1* ]] || fail "1.0.1 not prepended (newest first)"

# idempotent: re-running 1.0.1 leaves exactly one 1.0.1 item
"$here/update-appcast.sh" 1.0.1 1000001 "$tmp/Slipreel-1.0.1.dmg" \
  "https://example.com/Slipreel-1.0.1.dmg" "$appcast"
count="$(grep -c '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>' "$appcast")"
[[ "$count" == "1" ]] || fail "duplicate 1.0.1 items ($count)"

# well-formed XML (skip gracefully if xmllint is absent)
if command -v xmllint >/dev/null; then
  xmllint --noout "$appcast" || fail "appcast is not well-formed XML"
fi

echo "update-appcast.test.sh: OK"
