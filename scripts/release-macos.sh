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

# Derive the monotonic build number early (needs die()/log() defined above so a
# malformed version prints the intended diagnostic, not "die: command not found").
# shellcheck source=scripts/lib/version.sh
source "$ROOT/scripts/lib/version.sh"
BUILD_NUMBER="$(derive_build_number "$VERSION")" \
  || die "invalid version '$VERSION' (need MAJOR.MINOR.PATCH, minor/patch < 1000)"

# Remove the DMG staging dir and the notarization zip on any exit, so a
# failed create-dmg/notarize does not leak a ~100MB copy of the app.
cleanup() {
  [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"
  [[ -n "${APP_ZIP:-}" ]] && rm -f "$APP_ZIP"
  return 0
}
trap cleanup EXIT

# notarytool auth resolved once into an array (never word-split): a local
# keychain profile, or the CI API-key triple. Populated by preflight so a
# missing-credentials `die` aborts the whole script, not just a subshell.
NOTARY_ARGS=()
resolve_notary_args() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    die "no notary credentials: set NOTARY_PROFILE, or NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER (see docs/release/SETUP.md)"
  fi
}

# Submit to Apple's notary service and wait; on failure, print the detailed
# log (fetched by the submission id from the submit output) and abort.
notarize() { # notarize <path-to-.zip-or-.dmg>
  local target="$1" out subid
  # notarytool 1.x can exit 0 even when the final status is Invalid, so do not
  # trust the exit code — capture the output and require "status: Accepted".
  out="$(xcrun notarytool submit "$target" "${NOTARY_ARGS[@]}" --wait 2>&1 || true)"
  printf '%s\n' "$out"
  subid="$(printf '%s\n' "$out" | awk '/^ *id:/{print $2; exit}')"
  if ! grep -qE "status: Accepted" <<<"$out"; then
    [[ -n "$subid" ]] && xcrun notarytool log "$subid" "${NOTARY_ARGS[@]}" >&2 2>/dev/null || true
    die "notarization was NOT Accepted for $target (Apple notary log above)"
  fi
}

# --- preflight ---------------------------------------------------------------
log "preflight"
command -v xcrun >/dev/null || die "Xcode command line tools required"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no 'Developer ID Application' certificate in the keychain (see docs/release/SETUP.md)"
command -v create-dmg >/dev/null || die "create-dmg not found: brew install create-dmg (build-machine only)"
resolve_notary_args   # validates credentials are present (populates NOTARY_ARGS) before the long build
mkdir -p "$DIST"

# --- stage 1: build ----------------------------------------------------------
# Stamp the real publish date into build_release_date.g.dart FIRST, so the
# compiled app carries today's date for the one-time export ceiling (spec
# §2/§4) instead of the stale checked-in value.
log "stamping build release date"
"$ROOT/scripts/stamp-build-date.sh" || die "failed to stamp build release date"
log "building Slipreel $VERSION (clean release)"
log "release $VERSION -> CFBundleShortVersionString $VERSION, CFBundleVersion $BUILD_NUMBER"
( cd "$APP_PKG" && $FLUTTER clean >/dev/null \
    && $FLUTTER build macos --release \
        --build-name="$VERSION" --build-number="$BUILD_NUMBER" ) \
  || die "flutter build macos --release failed"
[[ -d "$APP" ]] || die "expected app not found at $APP"

# --- stage 1.5: re-sign Sparkle's nested code (inside-out) -------------------
# Xcode/CocoaPods embed Sparkle.framework but do NOT re-sign its nested helpers
# (Autoupdate, Updater.app, XPCServices) with Developer ID + a secure timestamp,
# so notarization rejects them ("not signed with a valid Developer ID
# certificate" / "does not include a secure timestamp"). Sign them explicitly
# inside-out, then re-seal the app so its signature covers the new signatures.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  log "signing Sparkle.framework nested code (Developer ID + hardened + timestamp)"
  # Innermost first (globs tolerate the version letter B/C/...): the XPC
  # services and the Updater app (bundles), then the Autoupdate tool, then the
  # framework itself, then the whole app.
  sp_items=()
  while IFS= read -r it; do [[ -n "$it" ]] && sp_items+=("$it"); done < <(
    find "$SPARKLE_FW"/Versions/*/XPCServices -maxdepth 1 -name '*.xpc' 2>/dev/null
    find "$SPARKLE_FW"/Versions/* -maxdepth 1 -name 'Updater.app' 2>/dev/null
    find "$SPARKLE_FW"/Versions/* -maxdepth 1 -name 'Autoupdate' -type f 2>/dev/null
  )
  for it in ${sp_items[@]+"${sp_items[@]}"}; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$it" \
      || die "failed to sign Sparkle component: $it"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_FW" \
    || die "failed to sign Sparkle.framework"
  # Re-seal the app (top level only; nested Helpers/Sparkle keep their now-valid
  # signatures). Pass the same entitlements or they are stripped.
  codesign --force --options runtime --timestamp \
    --entitlements "$APP_PKG/macos/Runner/Release.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP" \
    || die "failed to re-sign the app bundle after Sparkle re-sign"
  log "Sparkle nested code signed + app re-sealed"
fi

# --- stage 2: verify signature ----------------------------------------------
log "verifying Developer ID signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP" \
  || die "codesign verification failed for the app bundle"
for b in ffmpeg ffprobe whisper-cli; do
  [[ -f "$APP/Contents/Helpers/$b" ]] || die "Helpers/$b missing from the bundle"
  # Capture then grep (not `codesign ... | grep -q`): under pipefail a transient
  # codesign read failure on the fresh bundle would otherwise be misreported as
  # "not hardened". Separate the two and surface the real flags on mismatch.
  hdr="$(codesign --display --verbose=2 "$APP/Contents/Helpers/$b" 2>&1)" \
    || die "codesign could not read Helpers/$b:"$'\n'"$hdr"
  grep -q "flags=.*runtime" <<<"$hdr" \
    || die "Helpers/$b is not hardened ($(grep -oE 'flags=[^ ]+' <<<"$hdr" || echo 'no flags line'))"
done
# Sparkle ships nested executables (Autoupdate, Updater.app, XPC services)
# inside Sparkle.framework; each must be hardened or notarization rejects the
# bundle. Xcode's deep-sign over use_frameworks! normally covers embedded
# frameworks — assert it here (capture-then-grep, same rationale as the
# Helpers loop) to fail before the notarization round-trip, not after. Only
# Mach-O *executables* need the runtime flag; skip the Sparkle dylib itself.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE_FW" ]] || die "Sparkle.framework missing from the bundle (auto_updater not embedded?)"
while IFS= read -r macho; do
  [[ "$(file -b "$macho")" == *"Mach-O"*"executable"* ]] || continue
  # verbose=4 surfaces both the hardened-runtime flag AND the signing Authority,
  # so we catch "hardened but ad-hoc/Apple-Development-signed" (which notary
  # rejects) — not just a missing runtime flag.
  fhdr="$(codesign --display --verbose=4 "$macho" 2>&1)" \
    || die "codesign could not read $macho:"$'\n'"$fhdr"
  grep -q "flags=.*runtime" <<<"$fhdr" \
    || die "Sparkle executable not hardened: $macho ($(grep -oE 'flags=[^ ]+' <<<"$fhdr" || echo 'no flags line'))"
  grep -q "Authority=Developer ID Application" <<<"$fhdr" \
    || die "Sparkle executable not Developer ID signed: $macho (authorities: $(grep -oE 'Authority=[^)]*\)?' <<<"$fhdr" | tr '\n' ';' || echo none))"
done < <(find "$SPARKLE_FW" -type f -perm -111)
log "Sparkle.framework nested executables hardened + Developer ID signed"
# Pre-notarization spctl may report "rejected (not notarized)"; that is expected
# here and resolved after stapling. Just confirm the signing source is Developer ID.
# Capture then grep (same rationale as the Helper loop: avoid a pipefail
# false-negative from a transient codesign read on the fresh bundle).
app_sig="$(codesign --display --verbose=2 "$APP" 2>&1)" \
  || die "codesign could not read the app bundle:"$'\n'"$app_sig"
grep -q "Authority=Developer ID Application" <<<"$app_sig" \
  || die "app is not signed by a Developer ID Application authority (authorities: $(grep -oE 'Authority=[^)]*\)?' <<<"$app_sig" | tr '\n' ';' || echo none))"
log "signature + hardened runtime verified"

# --- stage 3: notarize the app ----------------------------------------------
APP_ZIP="$DIST/Slipreel-$VERSION-app.zip"
log "notarizing the app"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
rm -f "$APP_ZIP"

# --- stage 4: staple the app ------------------------------------------------
log "stapling the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" || die "stapler validate failed for the app"

# --- stage 5: build the DMG -------------------------------------------------
DMG="$DIST/Slipreel-$VERSION.dmg"
log "building $DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
create-dmg \
  --volname "Slipreel $VERSION" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Slipreel.app" 140 190 \
  --app-drop-link 400 190 \
  --no-internet-enable \
  "$DMG" "$STAGE/" \
  || die "create-dmg failed"
rm -rf "$STAGE"

# --- stage 6: sign + notarize + staple the DMG ------------------------------
log "signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" \
  || die "codesign failed for the DMG"
log "notarizing the DMG"
notarize "$DMG"
log "stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" || die "stapler validate failed for the DMG"

# --- stage 7: final Gatekeeper gate -----------------------------------------
log "final Gatekeeper assessment"
# spctl exits non-zero when it REJECTS, so capture unconditionally then look
# for "accepted" (a pipe under pipefail would conflate the two).
assess="$(spctl -a -vvv --type open --context context:primary-signature "$DMG" 2>&1 || true)"
grep -q "accepted" <<<"$assess" \
  || die "spctl did not accept the notarized DMG:"$'\n'"$assess"
log "DONE: $DMG ($(du -h "$DMG" | cut -f1))"

# --- stage 8: appcast entry (Sparkle auto-update) ---------------------------
# The Sparkle CLI (sign_update) ships inside the auto_updater pod, not on PATH
# or Homebrew. `pod install` (run by the build above) populated it here.
SPARKLE_BIN="$APP_PKG/macos/Pods/Sparkle/bin"
[[ -d "$SPARKLE_BIN" ]] && export PATH="$SPARKLE_BIN:$PATH"
# The enclosure points at the public download on slipreel.app where CI rsyncs
# the DMG. Written locally for inspection/e2e; CI seeds from the live feed and
# uploads the accumulating appcast (honors APPCAST_PATH so CI targets its copy).
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://slipreel.app/download}"
ENCLOSURE_URL="$DOWNLOAD_BASE/$(basename "$DMG")"
APPCAST_OUT="${APPCAST_PATH:-$DIST/appcast.xml}"
if command -v sign_update >/dev/null; then
  log "writing appcast entry -> $APPCAST_OUT"
  "$ROOT/scripts/update-appcast.sh" "$VERSION" "$BUILD_NUMBER" "$DMG" "$ENCLOSURE_URL" "$APPCAST_OUT" \
    || die "appcast generation failed"
else
  log "sparkle tools absent (brew install sparkle) — skipping appcast entry"
fi
