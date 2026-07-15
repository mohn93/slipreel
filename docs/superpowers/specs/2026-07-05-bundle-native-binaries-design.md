# Bundle Native CLI Binaries (ffmpeg + whisper-cli) — Design

**Date:** 2026-07-05
**Status:** Design — approved in brainstorming
**Branch:** `feat/bundle-native-binaries`
**Issue:** #19 (native-dependency slice of distribution #1)

## Problem

Slipreel shells out to two native CLI binaries at runtime: ffmpeg/ffprobe
(export encode, GIF export, probing, waveform + caption audio extraction,
crash-recovery re-mux, zoom-preview frame extraction) and whisper-cli
(caption speech-to-text). Both resolve from Homebrew/`PATH` today. A
distributed `.app` has a minimal `PATH` and no Homebrew, so a downloaded
build cannot export or caption. The binaries must ship inside the bundle.

## Decisions (locked in brainstorming)

- **Scope split with #1:** #19 delivers bundling + runtime wiring, verified
  from a release build with the existing ad-hoc signing. Developer ID
  signing + notarization of the app (including these binaries) lands in #1.
- **ffmpeg flavor:** LGPL, no libx264. The export encoder probes
  `h264_videotoolbox` first and VideoToolbox exists on every Mac Slipreel
  supports, so the libx264 fallback is effectively dev-only (still works on
  dev machines via Homebrew ffmpeg).
- **Sourcing:** a pinned build script in the repo produces the binaries into
  a gitignored vendor directory. No binaries in git, no release-asset
  ceremony; #1's release pipeline later runs or caches the same script.

## Constraints established by survey

- The app is **not sandboxed** (`com.apple.security.app-sandbox = false` in
  both entitlements files) and has **no hardened runtime configured**, so
  spawning bundled subprocesses needs no entitlement changes in #19.
- Every ffmpeg component the app uses is a **native ffmpeg component**
  (no external libraries needed): `h264` decode, native `aac` encoder,
  `h264_videotoolbox`, `pcm_s16le`, muxers/demuxers `mp4`/`wav`/`gif`/
  `rawvideo`/`lavfi`/`null`, and filters `scale pad setsar trim setpts
  concat fade fps palettegen paletteuse atrim asetpts atempo volume afade
  adelay amix` (survey: ffmpeg_encoder/decoder/probe, n_slice_filter_graph,
  gif_export_pipeline, waveform_extractor, caption_audio_extractor,
  recovery_service, frame_extractor_provider).
- Both resolvers (`FfmpegResolver`, `WhisperResolver`) already accept a
  `bundledPath` checked before Homebrew/`PATH`, and both facades
  (`Ffmpeg.resolver`, `Whisper.resolver`) are production injection points.
  `ffprobe` is derived as the sibling of the resolved ffmpeg.
- The whisper **model** already downloads + SHA-verifies on first use
  (`WhisperModelStore`) — only the binary is bundled.

## Design

### 1. Build script — `scripts/build-native-deps.sh`

One idempotent script, pinned source versions at the top, output to
`vendor/native/bin/` (gitignored):

- **ffmpeg + ffprobe** from a pinned ffmpeg release tarball. Built once per
  arch (arm64 + x86_64) and merged with `lipo`. Configure principles:
  - Native components only — **no external libraries** → the build is LGPL
    by default (no `--enable-gpl`, no `--enable-nonfree`).
  - `--disable-autodetect` — critical: prevents configure from silently
    linking Homebrew dylibs found on the build machine.
  - `--enable-videotoolbox` (explicit, since autodetect is off).
  - `--disable-network --disable-doc --disable-programs
    --enable-ffmpeg --enable-ffprobe` (no ffplay; no network protocols —
    all I/O is file/pipe).
  - No component allowlist-trimming in v1: everything we need is native,
    and trimming risks dropping an edge component for marginal size. A
    size-trim pass is a possible follow-up, not part of #19.
- **whisper-cli** from a pinned whisper.cpp tag, cmake static build
  (`BUILD_SHARED_LIBS=OFF`):
  - arm64: Metal enabled with `GGML_METAL_EMBED_LIBRARY=ON` (shaders
    embedded in the binary — no sidecar `.metallib` to bundle/sign).
  - x86_64: CPU-only (no Metal).
  - Merged with `lipo`.
- **Self-verification** (script fails loudly if any check fails):
  - `otool -L` on each output must list only `/usr/lib/*` and
    `/System/Library/*` dylibs (no Homebrew paths).
  - `lipo -info` confirms both arches present.
  - Smoke run: `ffmpeg -version`, `ffprobe -version`, `whisper-cli --help`;
    ffmpeg additionally must list `h264_videotoolbox` in `-encoders` and
    `aac` in `-encoders`. Run per-arch via `arch -x86_64` when the host
    supports Rosetta; warn and skip the foreign-arch smoke run otherwise.
- Build deps are checked up front with clear error messages: Xcode CLT,
  cmake (whisper), and nasm (ffmpeg's x86_64 assembly; build-machine-only
  dep, does not affect what ships or its licensing). If nasm is absent the
  script offers `--disable-x86asm` for the x86_64 slice as a slower-but-
  functional fallback.

### 2. Bundle integration — Xcode Run Script phase

A new Run Script build phase on the Runner target (`Slipreel`):

- Copies `vendor/native/bin/{ffmpeg,ffprobe,whisper-cli}` into
  `$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Helpers/`.
- **`Contents/Helpers/`**, not `Resources/` — Apple's convention for
  auxiliary executables; keeps #1's per-binary signing + notarization
  straightforward (executables in `Resources/` are a notarization smell).
- When `vendor/native/bin` is missing or empty the phase **warns and
  skips** — dev and CI builds keep working exactly as today (resolvers fall
  through to Homebrew/`PATH`).
- Phase placed after "Copy Bundle Resources"; ensures `Helpers/` exists;
  copies preserve the executable bit (`cp -f`).

### 3. Runtime wiring — `NativeDeps` startup hook

New small helper in `packages/screen_recorder/lib/` (app layer, not
engine — it knows about bundle layout):

- Derives the Helpers directory from `Platform.resolvedExecutable`
  (`…/Contents/MacOS/Slipreel` → `…/Contents/Helpers`), macOS-only guard.
- For each binary, wires the facade **only when the file exists**:
  `Ffmpeg.resolver = FfmpegResolver(bundledPath: <helpers>/ffmpeg)` and
  `Whisper.resolver = WhisperResolver(bundledPath: <helpers>/whisper-cli)`.
- Called once early in `main()` before any export/caption code can run.
- Injectable file-exists + executable-path seams for unit tests.
- `ffprobe` needs no wiring (sibling derivation from the resolved ffmpeg
  path already lands on `Helpers/ffprobe`).
- The existence check is belt-and-suspenders: resolvers already skip a
  dead `bundledPath`, but not wiring a missing file keeps resolver error
  messages (`searchedLocations`) honest on dev machines.

### 4. Licensing

- whisper.cpp is MIT — bundle its LICENSE text.
- ffmpeg LGPL build — ship attribution + the exact source/config used.
  Concretely: `docs/licenses/` (or an About-screen link later, #1's
  packaging decides surface) records the ffmpeg version, the configure
  line, a pointer to the ffmpeg source tarball, and the LGPL text. The
  build script emits this metadata (`vendor/native/BUILD_INFO.txt`)
  alongside the binaries so it can't drift from what was actually built.

## Error handling / edge cases

- **No vendor dir at build time** → copy phase warns + skips; app behaves
  exactly as today. No developer is forced to run a long ffmpeg build.
- **Bundled binary present but broken** → resolver returns it (existence
  check passes); the subprocess fails with the existing rich error paths
  (`FfmpegEncoder` stderr capture, caption error alerts). Acceptable: the
  build-script smoke checks make this a can't-happen for real releases.
- **Intel Macs**: universal binaries via lipo; whisper on x86_64 is
  CPU-only (slower captions, functional).
- **VideoToolbox declines on an end-user machine** → bundled ffmpeg has no
  libx264, export fails with the encoder-probe error. Accepted risk
  (VideoToolbox is present on all supported hardware); dev machines retain
  the fallback through Homebrew ffmpeg.
- **Rosetta absent on the build machine** → x86_64 smoke run skipped with
  a warning; lipo/otool checks still gate.

## Testing

- **Unit (screen_recorder):** `NativeDeps` — path derivation from a fake
  executable path; wires resolvers only when files exist; no-op on
  non-macOS; ffmpeg wired independently of whisper (one present, one
  absent).
- **Existing tests:** resolver bundledPath-first ordering is already
  covered (`ffmpeg_resolver_test`, `whisper_resolver_test`); suites stay
  green.
- **Script self-checks** double as its tests (otool/lipo/smoke gates).
- **Manual acceptance (the issue's bar, run before merge):** build release
  with the vendor binaries present, launch the app with Homebrew masked
  (`PATH=/usr/bin:/bin`, temporarily rename `/opt/homebrew/bin/ffmpeg` and
  `whisper-cli` or verify via process inspection that the Helpers binaries
  are the ones spawned), then: export an MP4 (with mixed audio), export a
  GIF, generate captions. All three must succeed via bundled binaries.

## Non-goals

- Developer ID signing, hardened runtime, notarization, DMG, auto-update
  (#1). The ad-hoc signature Flutter release builds already get is enough
  to run locally.
- Windows/Linux binary bundling (macOS-first policy).
- Bundling the whisper model (stays a first-run download).
- ffmpeg size-trimming below "native components only".
- CI changes (CI keeps `brew install ffmpeg`; release pipeline is #1).
