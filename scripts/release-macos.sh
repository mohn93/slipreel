#!/usr/bin/env bash
# Release pipeline for Slipreel (issue #1): build -> sign-verify -> notarize
# -> staple -> DMG -> sign/notarize/staple DMG. Single source of truth; the
# GitHub workflow imports credentials and calls this same script.
#
# Usage: scripts/release-macos.sh <version>
#   Local:  NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 1.0.0
#   CI:     NOTARY_KEY=notary.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=... scripts/release-macos.sh 1.0.0
# See docs/release/SETUP.md for credential setup.
set -euo pipefail

VERSION="${1:?usage: release-macos.sh <version> (e.g. 1.0.0)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PKG="$ROOT/packages/screen_recorder"
APP="$APP_PKG/build/macos/Build/Products/Release/Slipreel.app"
DIST="$ROOT/dist"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
FLUTTER="${FLUTTER:-fvm flutter}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# notarytool auth: local keychain profile, or the CI API-key triple.
notary_args() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    printf '%s\n' --keychain-profile "$NOTARY_PROFILE"
  elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    printf '%s\n' --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  else
    die "no notary credentials: set NOTARY_PROFILE, or NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER (see docs/release/SETUP.md)"
  fi
}

# Submit to Apple's notary service and wait; on failure, print the detailed
# log (fetched by the submission id from the submit output) and abort.
notarize() { # notarize <path-to-.zip-or-.dmg>
  local target="$1" out subid
  if out="$(xcrun notarytool submit "$target" $(notary_args) --wait 2>&1)"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" >&2
    subid="$(printf '%s\n' "$out" | awk '/^ *id:/{print $2; exit}')"
    [[ -n "$subid" ]] && xcrun notarytool log "$subid" $(notary_args) >&2 2>/dev/null || true
    die "notarization failed for $target (see log above)"
  fi
}

# --- preflight ---------------------------------------------------------------
log "preflight"
command -v xcrun >/dev/null || die "Xcode command line tools required"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no 'Developer ID Application' certificate in the keychain (see docs/release/SETUP.md)"
command -v create-dmg >/dev/null || die "create-dmg not found: brew install create-dmg (build-machine only)"
notary_args >/dev/null   # validates credentials are present before the long build
mkdir -p "$DIST"

# --- stage 1: build ----------------------------------------------------------
log "building Slipreel $VERSION (clean release)"
( cd "$APP_PKG" && $FLUTTER clean >/dev/null && $FLUTTER build macos --release )
[[ -d "$APP" ]] || die "expected app not found at $APP"

# --- stage 2: verify signature ----------------------------------------------
log "verifying Developer ID signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP" \
  || die "codesign verification failed for the app bundle"
for b in ffmpeg ffprobe whisper-cli; do
  codesign --display --verbose=2 "$APP/Contents/Helpers/$b" 2>&1 | grep -q "flags=.*runtime" \
    || die "Helpers/$b is not signed with the hardened runtime"
done
# Pre-notarization spctl may report "rejected (not notarized)"; that is expected
# here and resolved after stapling. Just confirm the signing source is Developer ID.
codesign --display --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || die "app is not signed by a Developer ID Application authority"
log "signature + hardened runtime verified"

# --- stages 3-7 added in Task 5 ---------------------------------------------
log "sign+verify complete for $APP (notarize/DMG stages follow)"
