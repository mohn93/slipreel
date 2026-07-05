# Bundle Native Binaries (ffmpeg + whisper-cli) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A release build of Slipreel.app carries its own ffmpeg, ffprobe, and whisper-cli in `Contents/Helpers/`, so export and captions work on a machine with no Homebrew (issue #19).

**Architecture:** A pinned build script produces static universal LGPL binaries into gitignored `vendor/native/bin/`; an Xcode Run Script phase copies them into the bundle when present (warns + skips when absent); a `NativeDeps` startup hook wires `Ffmpeg.resolver`/`Whisper.resolver` `bundledPath` only when the bundled files exist. Spec: `docs/superpowers/specs/2026-07-05-bundle-native-binaries-design.md`.

**Tech Stack:** bash build script (ffmpeg autotools + whisper.cpp cmake + lipo), Xcode PBXShellScriptBuildPhase, Dart (Flutter, screen_recorder package).

## Global Constraints

- ffmpeg build must be LGPL: no `--enable-gpl`, no `--enable-nonfree`, no external libraries, `--disable-autodetect` mandatory.
- Bundled binaries live in `Contents/Helpers/` (NOT `Resources/`).
- No binaries committed to git: `vendor/` is gitignored.
- Dev/CI builds with no `vendor/native/bin` must build and behave exactly as today (copy phase warns + skips; resolvers fall back to Homebrew/PATH).
- ffmpeg and ffprobe are an atomic pair everywhere (ffprobe resolves as ffmpeg's sibling): the copy phase ships both-or-neither, and `NativeDeps` wires ffmpeg only when both exist.
- Do NOT run `dart format` on existing files (repo convention — pinned formatter reflows unrelated lines).
- Flutter commands run via `fvm flutter`. Tests: `cd packages/screen_recorder && fvm flutter test <path>`.
- macOS deployment target 13.0 for all built binaries (`-mmacosx-version-min=13.0` / `CMAKE_OSX_DEPLOYMENT_TARGET=13.0`).
- Pinned versions (bump deliberately, never silently): ffmpeg `7.1.1`, whisper.cpp `v1.7.5`.

---

### Task 1: Copy script + Xcode Run Script phase + .gitignore

**Files:**
- Create: `scripts/copy-native-deps.sh`
- Modify: `.gitignore` (add `vendor/`)
- Modify: `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj` (new build phase)

**Interfaces:**
- Consumes: `vendor/native/bin/{ffmpeg,ffprobe,whisper-cli}` and `vendor/native/licenses/*` + `vendor/native/BUILD_INFO.txt` (produced later by Task 3/4 — absent for now, which is a supported state).
- Produces: `Slipreel.app/Contents/Helpers/{ffmpeg,ffprobe,whisper-cli}` and `Contents/Resources/licenses/*` in built apps when the vendor dir is populated.

- [ ] **Step 1: Write `scripts/copy-native-deps.sh`**

```bash
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
```

- [ ] **Step 2: Make it executable and test both states standalone**

```bash
chmod +x scripts/copy-native-deps.sh
# State 1: no vendor dir -> warns, exit 0, no Helpers created
STAGE=$(mktemp -d)
mkdir -p "$STAGE/Slipreel.app/Contents"
BUILT_PRODUCTS_DIR="$STAGE" CONTENTS_FOLDER_PATH="Slipreel.app/Contents" scripts/copy-native-deps.sh
test ! -e "$STAGE/Slipreel.app/Contents/Helpers" && echo "STATE1 OK"
# State 2: fake vendor binaries -> copied with executable bit
mkdir -p vendor/native/bin vendor/native/licenses
printf '#!/bin/sh\necho fake\n' > vendor/native/bin/ffmpeg
cp vendor/native/bin/ffmpeg vendor/native/bin/ffprobe
cp vendor/native/bin/ffmpeg vendor/native/bin/whisper-cli
chmod +x vendor/native/bin/*
echo "fake license" > vendor/native/licenses/TEST.txt
BUILT_PRODUCTS_DIR="$STAGE" CONTENTS_FOLDER_PATH="Slipreel.app/Contents" scripts/copy-native-deps.sh
test -x "$STAGE/Slipreel.app/Contents/Helpers/ffmpeg" \
  && test -x "$STAGE/Slipreel.app/Contents/Helpers/whisper-cli" \
  && test -f "$STAGE/Slipreel.app/Contents/Resources/licenses/TEST.txt" \
  && echo "STATE2 OK"
# State 3: ffmpeg without ffprobe -> pair NOT copied, whisper still copied
rm -rf "$STAGE/Slipreel.app/Contents/Helpers" vendor/native/bin/ffprobe
BUILT_PRODUCTS_DIR="$STAGE" CONTENTS_FOLDER_PATH="Slipreel.app/Contents" scripts/copy-native-deps.sh
test ! -e "$STAGE/Slipreel.app/Contents/Helpers/ffmpeg" \
  && test -x "$STAGE/Slipreel.app/Contents/Helpers/whisper-cli" \
  && echo "STATE3 OK"
rm -rf "$STAGE" vendor
```

Expected: `STATE1 OK`, `STATE2 OK`, `STATE3 OK` printed.

- [ ] **Step 3: Add `vendor/` to .gitignore**

Append to the root `.gitignore` (after the `# macOS` section):

```
# Vendored native binaries (built locally by scripts/build-native-deps.sh)
vendor/
```

- [ ] **Step 4: Add the Xcode Run Script phase**

Edit `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj` with two changes:

(a) In the Runner target's `buildPhases` list (the one containing `3399D490228B24CF009A79C7 /* ShellScript */`), add the new phase AFTER that line:

```
			buildPhases = (
				9D76105B1AA7050F05CB0966 /* [CP] Check Pods Manifest.lock */,
				33CC10E92044A3C60003C045 /* Sources */,
				33CC10EA2044A3C60003C045 /* Frameworks */,
				33CC10EB2044A3C60003C045 /* Resources */,
				33CC110E2044A8840003C045 /* Bundle Framework */,
				3399D490228B24CF009A79C7 /* ShellScript */,
				AA19DEB5000000000000BB01 /* Bundle Native Deps */,
				592EA6CB5ED2737DDF6BA447 /* [CP] Embed Pods Frameworks */,
			);
```

(b) In the `/* Begin PBXShellScriptBuildPhase section */`, add this block immediately after the closing `};` of the `3399D490228B24CF009A79C7 /* ShellScript */` block:

```
		AA19DEB5000000000000BB01 /* Bundle Native Deps */ = {
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
			);
			name = "Bundle Native Deps";
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "\"$SRCROOT/../../../scripts/copy-native-deps.sh\"\n";
		};
```

(`$SRCROOT` is `packages/screen_recorder/macos`, so `../../..` is the repo root. `alwaysOutOfDate = 1` matches the sibling Flutter phase — the phase must re-run when the vendor dir changes, which Xcode can't track.)

- [ ] **Step 5: Verify a build with no vendor dir still succeeds**

```bash
cd packages/screen_recorder && fvm flutter build macos --debug 2>&1 | tail -5
```

Expected: build succeeds; the Xcode log (add `-v` if needed) contains the `warning: vendor/native/bin/... incomplete` line; `build/macos/Build/Products/Debug/Slipreel.app/Contents/Helpers` does not exist.

- [ ] **Step 6: Commit**

```bash
git add scripts/copy-native-deps.sh .gitignore packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj
git commit -m "build(macos): Bundle Native Deps copy phase (warn+skip when vendor absent)"
```

---

### Task 2: NativeDeps startup hook

**Files:**
- Create: `packages/screen_recorder/lib/platform/native_deps.dart`
- Create: `packages/screen_recorder/test/platform/native_deps_test.dart`
- Modify: `packages/screen_recorder/lib/main.dart:68-73` (call in `main()`)

**Interfaces:**
- Consumes: `FfmpegResolver(bundledPath:)` / `Ffmpeg.resolver` from `package:slipreel_engine/export/ffmpeg_resolver.dart`; `WhisperResolver(bundledPath:)` / `Whisper.resolver` from `package:slipreel_engine/captions/whisper_resolver.dart`.
- Produces: `NativeDeps.wireBundledBinaries({String? executablePath, bool Function(String path)? fileExists})` — static, void, called once early in `main()`.

- [ ] **Step 1: Write the failing tests**

`packages/screen_recorder/test/platform/native_deps_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/platform/native_deps.dart';
import 'package:slipreel_engine/captions/whisper_resolver.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

void main() {
  const exe = '/Applications/Slipreel.app/Contents/MacOS/Slipreel';
  const helpers = '/Applications/Slipreel.app/Contents/Helpers';

  tearDown(() {
    Ffmpeg.resetForTesting();
    Whisper.resetForTesting();
  });

  test('wires both resolvers when all bundled binaries exist', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (_) => true,
    );
    expect(Ffmpeg.resolver.bundledPath, '$helpers/ffmpeg');
    expect(Whisper.resolver.bundledPath, '$helpers/whisper-cli');
  });

  test('does not wire ffmpeg when ffprobe is missing (atomic pair)', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (p) => !p.endsWith('/ffprobe'),
    );
    expect(Ffmpeg.resolver.bundledPath, isNull);
    expect(Whisper.resolver.bundledPath, '$helpers/whisper-cli');
  });

  test('wires whisper independently when ffmpeg pair is absent', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (p) => p.endsWith('/whisper-cli'),
    );
    expect(Ffmpeg.resolver.bundledPath, isNull);
    expect(Whisper.resolver.bundledPath, '$helpers/whisper-cli');
  });

  test('wires nothing when no bundled binaries exist', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (_) => false,
    );
    expect(Ffmpeg.resolver.bundledPath, isNull);
    expect(Whisper.resolver.bundledPath, isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd packages/screen_recorder && fvm flutter test test/platform/native_deps_test.dart
```

Expected: FAIL — `native_deps.dart` does not exist.

- [ ] **Step 3: Write `packages/screen_recorder/lib/platform/native_deps.dart`**

```dart
import 'dart:io';

import 'package:slipreel_engine/captions/whisper_resolver.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Wires the ffmpeg/whisper resolvers to the binaries bundled inside the
/// app (Slipreel.app/Contents/Helpers), when present. A dev build with no
/// bundled binaries wires nothing, so the resolvers keep their default
/// Homebrew -> PATH fallback and their not-found errors stay honest about
/// which locations were actually searched.
class NativeDeps {
  NativeDeps._();

  /// Call once early in main(), before any export/caption code can run.
  ///
  /// [executablePath] and [fileExists] are test seams; production uses
  /// [Platform.resolvedExecutable] and the real filesystem.
  static void wireBundledBinaries({
    String? executablePath,
    bool Function(String path)? fileExists,
  }) {
    if (!Platform.isMacOS) return;
    final exe = executablePath ?? Platform.resolvedExecutable;
    final exists = fileExists ?? (p) => File(p).existsSync();
    // .../Contents/MacOS/Slipreel -> .../Contents/Helpers
    final helpers = '${File(exe).parent.parent.path}/Helpers';

    final ffmpeg = '$helpers/ffmpeg';
    // ffprobe is resolved as ffmpeg's sibling, so only wire a bundle that
    // ships both.
    if (exists(ffmpeg) && exists('$helpers/ffprobe')) {
      Ffmpeg.resolver = FfmpegResolver(bundledPath: ffmpeg);
      AppLogger.platform.i('Bundled ffmpeg wired: $ffmpeg');
    }

    final whisper = '$helpers/whisper-cli';
    if (exists(whisper)) {
      Whisper.resolver = WhisperResolver(bundledPath: whisper);
      AppLogger.platform.i('Bundled whisper-cli wired: $whisper');
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd packages/screen_recorder && fvm flutter test test/platform/native_deps_test.dart
```

Expected: 4 tests PASS.

- [ ] **Step 5: Call it from `main()`**

In `packages/screen_recorder/lib/main.dart`, after `AppLogger.initialize(level: Level.debug);` (line 72) add:

```dart
  // Prefer the CLI binaries bundled in Contents/Helpers (release builds);
  // dev builds without them keep resolving from Homebrew/PATH.
  NativeDeps.wireBundledBinaries();
```

and add the import alongside the other relative imports (after `import 'platform/window_chrome_channel.dart';` keeps the group sorted — match surrounding style):

```dart
import 'platform/native_deps.dart';
```

- [ ] **Step 6: Analyze + full package test**

```bash
cd packages/screen_recorder && fvm flutter analyze --no-fatal-infos && fvm flutter test
```

Expected: analyze clean (warnings fatal), all tests pass.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/platform/native_deps.dart packages/screen_recorder/test/platform/native_deps_test.dart packages/screen_recorder/lib/main.dart
git commit -m "feat(startup): wire bundled ffmpeg/whisper-cli from Contents/Helpers when present"
```

---

### Task 3: Build script — skeleton + ffmpeg

**Files:**
- Create: `scripts/build-native-deps.sh`

**Interfaces:**
- Produces: `vendor/native/bin/{ffmpeg,ffprobe}` (universal, static, LGPL), `vendor/native/licenses/FFMPEG-COPYING.LGPLv2.1`, `vendor/native/BUILD_INFO.txt`. CLI: `scripts/build-native-deps.sh [--only=ffmpeg|whisper]`.
- Consumed by: Task 1's copy phase, Task 4 (adds the whisper branch to this same script).

**Note for the implementer:** ffmpeg compiles for ~5–10 minutes per arch. Run long steps with a generous timeout (or in the background and poll); do not kill a `make` mid-flight and conclude failure.

- [ ] **Step 1: Write `scripts/build-native-deps.sh`**

```bash
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

# --- whisper (implemented in Task 4) ----------------------------------------

build_whisper() {
  die "whisper build not implemented yet (Task 4)"
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
```

- [ ] **Step 2: Make executable, run the ffmpeg build**

```bash
chmod +x scripts/build-native-deps.sh
scripts/build-native-deps.sh --only=ffmpeg
```

Expected: downloads the tarball, builds both arches (long — minutes per arch), then prints `==> ffmpeg + ffprobe OK` and `==> done`. All self-checks (universal, system-dylibs-only, encoders/filters present, lavfi probe) pass.

- [ ] **Step 3: Spot-check the outputs by hand**

```bash
lipo -info vendor/native/bin/ffmpeg vendor/native/bin/ffprobe
otool -L vendor/native/bin/ffmpeg | head -8
vendor/native/bin/ffmpeg -version | head -2
ls -la vendor/native/licenses/
```

Expected: both universal; only `/usr/lib` + `/System/Library` dylibs; version banner shows `--disable-autodetect` in the configuration line; `FFMPEG-COPYING.LGPLv2.1` present. The banner's configuration must NOT contain `--enable-gpl` or `--enable-nonfree`.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-native-deps.sh
git commit -m "build: pinned static universal LGPL ffmpeg/ffprobe build script (#19)"
```

---

### Task 4: Build script — whisper-cli

**Files:**
- Modify: `scripts/build-native-deps.sh` (replace the `build_whisper` stub)

**Interfaces:**
- Consumes: the helpers from Task 3 (`require`, `verify_universal`, `verify_system_dylibs_only`, `smoke`, `$WORK/$BIN/$LIC`, `$WHISPER_VERSION`, `$DEPLOYMENT_TARGET`, `$JOBS`).
- Produces: `vendor/native/bin/whisper-cli` (universal, static, Metal embedded on arm64), `vendor/native/licenses/WHISPER-LICENSE-MIT`.

**Note for the implementer:** whisper.cpp builds in ~1–3 minutes per arch. Same long-step guidance as Task 3.

- [ ] **Step 1: Replace the `build_whisper` stub**

```bash
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
```

(`GGML_NATIVE=OFF` on BOTH arches — this is a distribution build; `-march=native`-style tuning to the build machine's CPU would crash or misbehave on end-user CPUs. If the `--target whisper-cli` name is rejected by the pinned tag, list targets with `cmake --build "$builddir" --target help` — older tags call it `main` — and copy the produced binary accordingly; do not silently build all targets.)

- [ ] **Step 2: Run the whisper build**

```bash
scripts/build-native-deps.sh --only=whisper
```

Expected: clones the pinned tag, builds both arches, prints `==> whisper-cli OK` and `==> done`; all self-checks pass.

- [ ] **Step 3: Spot-check the binary**

```bash
lipo -info vendor/native/bin/whisper-cli
otool -L vendor/native/bin/whisper-cli
vendor/native/bin/whisper-cli --help 2>&1 | head -3
cat vendor/native/BUILD_INFO.txt
```

Expected: universal; only system dylibs (Metal/Foundation/Accelerate frameworks under `/System/Library` are fine); help text prints; BUILD_INFO lists both binaries with versions and sources.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-native-deps.sh
git commit -m "build: static universal whisper-cli (Metal embedded on arm64) in build-native-deps (#19)"
```

---

### Task 5: Attribution docs

**Files:**
- Create: `docs/licenses/README.md`

**Interfaces:**
- Consumes: nothing (pure docs). References the script and vendor layout from Tasks 3–4.

- [ ] **Step 1: Write `docs/licenses/README.md`**

```markdown
# Third-party native binaries

Slipreel bundles two CLI binaries in `Slipreel.app/Contents/Helpers/`,
built by `scripts/build-native-deps.sh` (pinned versions at the top of
that script). The license texts and the exact build provenance
(`BUILD_INFO.txt`: versions, source URLs, configure/cmake lines) ship
inside the app at `Contents/Resources/licenses/`.

## ffmpeg / ffprobe — LGPL v2.1+

Built from the official source release with native components only: no
external libraries, no `--enable-gpl`, no `--enable-nonfree`. Hardware
H.264 encoding uses Apple VideoToolbox. Under the LGPL we must (and do)
ship the license text and state where to obtain the corresponding
source: the exact tarball URL and full configure line are recorded in
the bundled `BUILD_INFO.txt`. No ffmpeg source modifications are made.

## whisper-cli (whisper.cpp) — MIT

Built from the pinned upstream tag with Metal support embedded on Apple
Silicon. MIT requires shipping the copyright notice + license text,
which rides in `Contents/Resources/licenses/WHISPER-LICENSE-MIT`.

## Updating

Bump the pinned version in `scripts/build-native-deps.sh`, re-run it
(both binaries re-verify: universal, statically self-contained, smoke
runs), rebuild the app. Binary updates reach users through app updates.
```

- [ ] **Step 2: Commit**

```bash
git add docs/licenses/README.md
git commit -m "docs: third-party binary attribution + licensing notes (#19)"
```

---

### Task 6: Release-build bundle verification

**Files:**
- No new files — builds the app and verifies the bundle. (Fix anything found; likely files: `scripts/copy-native-deps.sh`, the pbxproj phase.)

**Interfaces:**
- Consumes: everything above (vendor binaries present from Tasks 3–4).

- [ ] **Step 1: Release build with vendor binaries present**

```bash
cd packages/screen_recorder && fvm flutter build macos --release 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 2: Verify the bundle contents**

```bash
APP=packages/screen_recorder/build/macos/Build/Products/Release/Slipreel.app
ls -la "$APP/Contents/Helpers/"
ls "$APP/Contents/Resources/licenses/"
lipo -info "$APP/Contents/Helpers/ffmpeg"
```

Expected: `ffmpeg`, `ffprobe`, `whisper-cli` all present and executable in `Helpers/`; license files + `BUILD_INFO.txt` in `Resources/licenses/`; ffmpeg universal.

- [ ] **Step 3: Clean-environment subprocess sanity**

Prove the bundled binaries run with no Homebrew on `PATH` and no inherited env:

```bash
env -i PATH=/usr/bin:/bin "$APP/Contents/Helpers/ffmpeg" -version | head -1
env -i PATH=/usr/bin:/bin "$APP/Contents/Helpers/ffprobe" -version | head -1
env -i PATH=/usr/bin:/bin "$APP/Contents/Helpers/whisper-cli" --help >/dev/null && echo "whisper OK"
```

Expected: version banners + `whisper OK`, no dyld errors.

- [ ] **Step 4: Verify the app wires the bundled paths at launch**

Launch the release app and check the log lines from Task 2 (`Bundled ffmpeg wired: ...` / `Bundled whisper-cli wired: ...`). Kill any running instance first (repo lesson: `osascript -e 'quit app "Slipreel"'; pkill -f Slipreel.app`), then `open -n "$APP"`. Console.app or `log stream --predicate 'process == "Slipreel"'` shows the app log.

Expected: both "wired" lines appear with `.../Contents/Helpers/...` paths.

- [ ] **Step 5: Commit any fixes; hand off for user acceptance**

The final acceptance (user-run, before merge): in the release app, export an MP4 with audio, export a GIF, and generate captions. Since `bundledPath` is first in the resolver candidate list and the wire log proves it is set, success of those three flows IS the proof the bundled binaries served them — no Homebrew masking needed.

```bash
git status --short   # commit any fixes made during verification
```

---

## Self-review notes

- Spec coverage: build script (Task 3/4), copy phase + Helpers location (Task 1), NativeDeps wiring + atomic ffmpeg/ffprobe pair (Task 2), licensing/BUILD_INFO (Tasks 3/4/5), acceptance (Task 6 + user gate). Non-goals untouched (no CI changes, no signing).
- The `--target whisper-cli` cmake target name and the `v1.7.5` tag are pinned from upstream conventions; Task 4 includes the recovery path if the pinned tag names the CLI target differently.
- CI stays green by construction: no vendor dir on runners → copy phase warns + skips; `native_deps_test` uses injected seams only.
