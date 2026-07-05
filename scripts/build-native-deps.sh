#!/usr/bin/env bash
# Builds the native CLI binaries Slipreel bundles (issue #19):
#   - ffmpeg + ffprobe: static, universal (arm64 + x86_64), LGPL
#     (native components only, no external libraries).
#   - whisper-cli: static, universal, Metal embedded on arm64 (Task 4).
# Output: vendor/native/bin (gitignored). Idempotent; re-run freely.
#
# Usage: scripts/build-native-deps.sh [--only=ffmpeg|whisper]
set -euo pipefail

FFMPEG_VERSION=7.1.1
WHISPER_VERSION=v1.7.5
DEPLOYMENT_TARGET=13.0
ARCHES=(arm64 x86_64)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/native"
BIN="$VENDOR/bin"
LIC="$VENDOR/licenses"
WORK="$VENDOR/work"
JOBS="$(sysctl -n hw.ncpu)"

ONLY=all
for arg in "$@"; do
  case "$arg" in
    --only=ffmpeg) ONLY=ffmpeg ;;
    --only=whisper) ONLY=whisper ;;
    *) echo "usage: $0 [--only=ffmpeg|whisper]" >&2; exit 2 ;;
  esac
done

mkdir -p "$BIN" "$LIC" "$WORK"

die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

# --- shared verification -----------------------------------------------------

verify_system_dylibs_only() {
  # otool -L prints a "<path> (architecture X):" header PER SLICE on a fat
  # binary; keep only the tab-indented dependency lines (headers are not
  # indented) so a universal binary does not flag its own header path.
  # [[:space:]] not \t: BSD grep does not reliably expand \t.
  local deps bad
  deps="$(otool -L "$1" | grep -E '^[[:space:]]' | awk '{print $1}')"
  # Fail closed: every self-contained macOS binary links at least
  # libSystem, so zero dependency lines means otool output we can't parse,
  # not a clean binary. Do not conclude "clean" from an unreadable check.
  [[ -n "$deps" ]] || die "$1: otool -L produced no parseable dependency lines"
  bad="$(printf '%s\n' "$deps" | grep -v -E '^(/usr/lib/|/System/Library/)' || true)"
  [[ -z "$bad" ]] || die "$(printf '%s links non-system libraries:\n%s' "$1" "$bad")"
}

verify_universal() {
  lipo -info "$1" | grep -q 'x86_64 arm64\|arm64 x86_64' \
    || die "$1 is not a universal (arm64 + x86_64) binary: $(lipo -info "$1")"
}

HAS_ROSETTA=0
if arch -x86_64 /usr/bin/true 2>/dev/null; then HAS_ROSETTA=1; fi

smoke() { # smoke <binary> <args...> : run natively, and under Rosetta if available
  "$@" >/dev/null 2>&1 || die "smoke run failed: $*"
  if [[ $HAS_ROSETTA -eq 1 ]]; then
    arch -x86_64 "$@" >/dev/null 2>&1 || die "x86_64 smoke run failed: $*"
  else
    echo "warning: Rosetta unavailable; skipped x86_64 smoke run of $1"
  fi
}

# --- ffmpeg ------------------------------------------------------------------

FFMPEG_CONFIGURE_FLAGS=""

build_ffmpeg_arch() {
  local arch="$1"
  local src="$WORK/ffmpeg-$FFMPEG_VERSION"
  local builddir="$WORK/ffmpeg-build-$arch"
  local cross=()
  if [[ "$arch" != "$(uname -m)" ]]; then
    cross=(--enable-cross-compile)
  fi
  local x86asm=()
  if [[ "$arch" == x86_64 ]] && ! command -v nasm >/dev/null 2>&1; then
    echo "warning: nasm not found (brew install nasm); building x86_64 slice with --disable-x86asm (slower, still correct)"
    x86asm=(--disable-x86asm)
  fi
  rm -rf "$builddir" && mkdir -p "$builddir"
  FFMPEG_CONFIGURE_FLAGS="--arch=$arch --target-os=darwin \
    --cc=clang --extra-cflags=-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET \
    --disable-autodetect --disable-network --disable-doc --disable-debug \
    --disable-programs --enable-ffmpeg --enable-ffprobe --enable-videotoolbox"
  (
    cd "$builddir"
    # ${arr[@]+"${arr[@]}"} instead of "${arr[@]}": macOS ships bash 3.2,
    # where expanding an empty array under `set -u` aborts as unbound.
    "$src/configure" \
      --arch="$arch" --target-os=darwin \
      ${cross[@]+"${cross[@]}"} ${x86asm[@]+"${x86asm[@]}"} \
      --cc=clang \
      --extra-cflags="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      --extra-ldflags="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      --disable-autodetect \
      --disable-network \
      --disable-doc \
      --disable-debug \
      --disable-programs --enable-ffmpeg --enable-ffprobe \
      --enable-videotoolbox
    make -j"$JOBS" ffmpeg ffprobe
  )
}

build_ffmpeg() {
  require curl "Needed to download the ffmpeg source tarball."
  local tarball="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
  if [[ ! -d "$WORK/ffmpeg-$FFMPEG_VERSION" ]]; then
    [[ -f "$tarball" ]] || curl -fL -o "$tarball" \
      "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    tar -xf "$tarball" -C "$WORK"
  fi

  for arch in "${ARCHES[@]}"; do
    echo "==> building ffmpeg $FFMPEG_VERSION for $arch"
    build_ffmpeg_arch "$arch"
  done

  for tool in ffmpeg ffprobe; do
    lipo -create \
      "$WORK/ffmpeg-build-arm64/$tool" \
      "$WORK/ffmpeg-build-x86_64/$tool" \
      -output "$BIN/$tool"
    chmod +x "$BIN/$tool"
    verify_universal "$BIN/$tool"
    verify_system_dylibs_only "$BIN/$tool"
    smoke "$BIN/$tool" -version
  done

  # The components the app actually uses must be present (spec section 1).
  "$BIN/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox \
    || die "bundled ffmpeg is missing the h264_videotoolbox encoder"
  "$BIN/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q ' aac ' \
    || die "bundled ffmpeg is missing the aac encoder"
  for f in amix adelay atempo palettegen paletteuse; do
    "$BIN/ffmpeg" -hide_banner -filters 2>/dev/null | grep -q "$f" \
      || die "bundled ffmpeg is missing the $f filter"
  done
  # lavfi virtual input backs the 1-frame VideoToolbox probe.
  "$BIN/ffmpeg" -hide_banner -f lavfi -i color=c=black:s=16x16:r=1:d=1 -f null - \
    >/dev/null 2>&1 || die "bundled ffmpeg cannot run the lavfi probe pipeline"

  cp -f "$WORK/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$LIC/FFMPEG-COPYING.LGPLv2.1"
  echo "==> ffmpeg + ffprobe OK -> $BIN"
}

# --- whisper -----------------------------------------------------------------

build_whisper_arch() {
  local arch="$1"
  local src="$WORK/whisper.cpp"
  local builddir="$WORK/whisper-build-$arch"
  local metal=(-DGGML_METAL=OFF)
  if [[ "$arch" == arm64 ]]; then
    # Embed the Metal shader library in the binary - no sidecar .metallib
    # to bundle or sign.
    metal=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  fi
  rm -rf "$builddir"
  cmake -S "$src" -B "$builddir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    "${metal[@]}"
  cmake --build "$builddir" --config Release -j "$JOBS" --target whisper-cli
}

build_whisper() {
  require git "Needed to clone whisper.cpp."
  require cmake "brew install cmake"
  if [[ ! -d "$WORK/whisper.cpp" ]]; then
    git clone --depth 1 --branch "$WHISPER_VERSION" \
      https://github.com/ggml-org/whisper.cpp "$WORK/whisper.cpp"
  fi

  for arch in "${ARCHES[@]}"; do
    echo "==> building whisper-cli $WHISPER_VERSION for $arch"
    build_whisper_arch "$arch"
  done

  lipo -create \
    "$WORK/whisper-build-arm64/bin/whisper-cli" \
    "$WORK/whisper-build-x86_64/bin/whisper-cli" \
    -output "$BIN/whisper-cli"
  chmod +x "$BIN/whisper-cli"
  verify_universal "$BIN/whisper-cli"
  verify_system_dylibs_only "$BIN/whisper-cli"
  smoke "$BIN/whisper-cli" --help

  cp -f "$WORK/whisper.cpp/LICENSE" "$LIC/WHISPER-LICENSE-MIT"
  echo "==> whisper-cli OK -> $BIN"
}

# --- build info --------------------------------------------------------------

write_build_info() {
  {
    echo "Slipreel bundled native binaries - build provenance"
    echo "built: $(date -u '+%Y-%m-%dT%H:%M:%SZ') on $(sw_vers -productVersion) $(uname -m)"
    echo ""
    echo "ffmpeg $FFMPEG_VERSION (LGPL, native components only)"
    echo "  source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    echo "  configure (per arch): $FFMPEG_CONFIGURE_FLAGS"
    echo ""
    echo "whisper.cpp $WHISPER_VERSION (MIT)"
    echo "  source: https://github.com/ggml-org/whisper.cpp (tag $WHISPER_VERSION)"
    echo "  cmake: -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF; arm64 adds -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON"
  } > "$VENDOR/BUILD_INFO.txt"
}

# --- main --------------------------------------------------------------------

require otool "Install the Xcode Command Line Tools: xcode-select --install"
require lipo "Install the Xcode Command Line Tools: xcode-select --install"
require clang "Install the Xcode Command Line Tools: xcode-select --install"

[[ "$ONLY" == whisper ]] || build_ffmpeg
[[ "$ONLY" == ffmpeg ]] || build_whisper
write_build_info
echo "==> done. Binaries in $BIN; provenance in $VENDOR/BUILD_INFO.txt"
