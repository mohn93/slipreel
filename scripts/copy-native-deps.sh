#!/usr/bin/env bash
# Xcode Run Script phase: copy vendored native CLI binaries into the app
# bundle (Contents/Helpers). Missing vendor binaries are a warning, not an
# error - dev/CI builds fall back to Homebrew/PATH at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/vendor/native/bin"
LIC="$ROOT/vendor/native/licenses"
APP="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR not set (run from Xcode)}/${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH not set (run from Xcode)}"
HELPERS="$APP/Helpers"

copied=0

# ffmpeg + ffprobe are an atomic pair: ffprobe is resolved at runtime as the
# sibling of ffmpeg, so shipping one without the other breaks probing.
if [[ -x "$BIN/ffmpeg" && -x "$BIN/ffprobe" ]]; then
  mkdir -p "$HELPERS"
  cp -f "$BIN/ffmpeg" "$BIN/ffprobe" "$HELPERS/"
  copied=$((copied + 2))
else
  echo "warning: vendor/native/bin/{ffmpeg,ffprobe} incomplete; app falls back to Homebrew/PATH (run scripts/build-native-deps.sh to bundle)"
fi

if [[ -x "$BIN/whisper-cli" ]]; then
  mkdir -p "$HELPERS"
  cp -f "$BIN/whisper-cli" "$HELPERS/"
  copied=$((copied + 1))
else
  echo "warning: vendor/native/bin/whisper-cli not found; captions fall back to Homebrew/PATH (run scripts/build-native-deps.sh to bundle)"
fi

# License texts + build provenance ride along whenever anything was bundled.
if [[ $copied -gt 0 && -d "$LIC" ]]; then
  mkdir -p "$APP/Resources/licenses"
  cp -f "$LIC"/* "$APP/Resources/licenses/"
  if [[ -f "$ROOT/vendor/native/BUILD_INFO.txt" ]]; then
    cp -f "$ROOT/vendor/native/BUILD_INFO.txt" "$APP/Resources/licenses/"
  fi
fi

echo "copy-native-deps: bundled $copied binaries into $HELPERS"
