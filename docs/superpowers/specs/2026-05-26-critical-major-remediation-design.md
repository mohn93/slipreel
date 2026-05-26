# Slipreel — Critical + Major Remediation Design

**Date:** 2026-05-26
**Status:** Approved (design)
**Scope:** All 🔴 Critical and 🟠 Major findings from the 2026-05-26 multi-agent architecture review. All 🟡 Minor findings are explicitly deferred.

## Background

A four-domain parallel review (engine, app, native/federation, cross-cutting) of the Slipreel
Melos monorepo found the architecture fundamentally sound but surfaced a set of release-blocking
and high-severity issues. This document specifies the remediation for the Critical and Major
findings. The work decomposes into five independent workstreams (A–E).

## Decisions

These were resolved with the user before writing this spec:

| # | Question | Decision |
|---|----------|----------|
| 1 | ffmpeg packaging | Runtime resolver with a drop-in hook for a bundled binary later. Do **not** source/bundle a binary in this effort. |
| 2 | Windows/Linux direction | macOS-first. Fix the channel-name break, document Win/Linux as unimplemented placeholders. No Win/Linux feature work. |
| 3 | Trim/speed/fade on export | Wire **all three** fully, in both the MP4 and GIF pipelines. |
| 4 | `agent_wires` dependency | Make it dev-only/optional so release builds, CI, and fresh clones do not require the external repo. |
| 5 | Isolate compositor | **Delete** the dead, untested isolate compositor and correct the docs. |
| 6 | `playback_screen` god-widget | **Full decomposition**: ExportService + TrimController + HoverScrubController, each unit-tested. |

## Out of Scope

All 🟡 Minor findings are deferred for a later pass and must not be addressed here:
default-only lint config, `FrameSettingsProvider` double-bookkeeping, `AudioTab` background-music
stub, model `toJson`/`toMap` naming inconsistency, engine `flutter/material.dart` imports,
`BoundedAsyncQueue` O(n) `removeAt(0)`, Flutter-template stub READMEs/CHANGELOGs, native debug
`print()` spam, `RecordingSettings.copyWith` optional-clearing, `FrameData.bytesPerRow` wire gap,
legacy spool-path dead code, `ZoomRegion.isActive` inclusivity, `_evenSize` 1px centering,
`EmaVelocityFilter` backward-scrub note.

---

## Workstream A — Export correctness (engine)

**Package:** `packages/slipreel_engine`

### A1. ffmpeg resolution (Critical #1)

**Problem:** `Process.start('ffmpeg', …)` at `ffmpeg_encoder.dart:137`, `ffmpeg_decoder.dart:46`,
`gif_export_pipeline.dart:119,191` relies on a bare PATH lookup. A sandboxed/packaged macOS app
has a minimal PATH and will not find ffmpeg.

**Design:**
- New `lib/export/ffmpeg_resolver.dart` exposing `FfmpegResolver` with a single
  `Future<String> resolve()` (and a sync-cached variant after first resolution).
- Resolution order: (1) bundled-asset path hook (a nullable override / well-known app-resource
  location, currently empty so the hook exists for a future bundled binary), (2) `/opt/homebrew/bin/ffmpeg`,
  (3) `/usr/local/bin/ffmpeg`, (4) `PATH` lookup via `Platform.environment['PATH']`.
- On failure throw a typed `FfmpegNotFoundException` carrying the searched locations.
- All three call sites resolve once and pass the absolute path to `Process.start`.
- The app surfaces `FfmpegNotFoundException` as a clear, actionable error dialog (handled in
  Workstream E's ExportService).

**Tests:** resolver picks the override first; falls through Homebrew → usr/local → PATH; throws
with searched-locations when none found (use an injectable file-existence + PATH seam so the test
does not depend on the host).

### A2. Process lifecycle + cancellation (Critical #2)

**Problem:** No `kill()` anywhere in `lib/export` except the isolate. On a mid-export failure the
encoder ffmpeg child is orphaned with an open stdin; the decoder is only stopped implicitly. No
cancellation mechanism exists.

**Design:**
- `FfmpegDecoder` and `FfmpegEncoder` hold their `Process` handle as a field and gain
  `Future<void> dispose()` / `void kill()` that terminate the subprocess and close pipes.
- `ExportPipeline` and `GifExportPipeline` wrap the run in `try/catch/finally`: on error or
  cancellation, kill encoder + decoder before rethrowing; in `finally`, ensure both are reaped.
- Add an export **cancellation token** (a simple `Completer`/flag passed into the pipeline). When
  tripped, the pipeline stops producing, kills subprocesses, and tears down via the same path as
  the error case.

**Tests:** simulated mid-export failure leaves no live subprocess (assert `kill` invoked on both);
cancellation token trips → pipeline stops and tears down; happy path still reaps cleanly.

### A3. stderr drain (Major #13)

**Problem:** stderr is consumed only after the data stream completes (`ffmpeg_decoder.dart:66`,
`ffmpeg_encoder.dart:170`), risking a pipe-fill deadlock if ffmpeg becomes chatty.

**Design:** attach a stderr listener at process start that accumulates into a buffer (bounded, for
diagnostics), instead of reading lazily at the end. Surface the captured stderr tail in error
messages.

**Tests:** unit-level — encoder/decoder register a stderr listener immediately on start (verify via
the process seam); captured stderr is included in the thrown error on non-zero exit.

### A4. Trim / playback speed / fades (Critical #3)

**Problem:** `playbackSpeed`/`fadeIn`/`fadeOut` round-trip through JSON but are never read by either
pipeline. `TrimSelection` lives only in `playback_screen.dart` and is never passed to the pipeline;
the decoder issues no `-ss`/`-t`. A trimmed clip exports full-length.

**Design:**
- Both `ExportPipeline` and `GifExportPipeline` accept the `TrimSelection`, `playbackSpeed`, and
  `fadeIn`/`fadeOut` from the project state.
- **Trim:** decoder gets `-ss <start>` / `-t <duration>`; `expectedFrames` recomputed for the
  trimmed range; the cursor/zoom/scene time base is **offset by the trim start** so the
  deterministic focal track, cursor motion, and zoom regions align to the trimmed output (this is
  the subtlest part — see Risks). Audio mix range and progress reporting are gated on the trimmed
  (and speed-adjusted) range.
- **Playback speed:** video `setpts=PTS/<speed>`; audio `atempo` (chained for factors outside
  `[0.5, 2.0]`). Frame timeline / `expectedFrames` adjusted accordingly.
- **Fades:** video `fade=t=in` / `fade=t=out`; audio `afade=t=in` / `afade=t=out`, positioned
  within the trimmed+speed-adjusted range.
- Interaction with the existing audio-mix arg builder must be preserved (the `-vf` vs
  `-filter_complex` mutual-exclusion guard already covered by tests must keep passing).

**Tests:** trimmed export asserts output duration ≈ trim length; **cursor/zoom alignment after
trim** (not just duration); speed factor changes output duration and frame count; fade args emitted
correctly; combined trim+speed+fade arg-building; GIF pipeline parity.

### A5. Delete isolate compositor (Major #10)

**Problem:** `isolate_frame_compositor.dart` is documented as the "production default" in
`export_compositor.dart:13` but `useIsolateCompositor` defaults `false` everywhere and the path is
untested.

**Design:** delete `isolate_frame_compositor.dart` and the `useIsolateCompositor` flag/branch in
`export_pipeline.dart`. Update `export_compositor.dart` docs to describe main-isolate compositing
accurately. Remove now-dead references.

**Tests:** existing pipeline tests stay green; no test references the deleted class.

---

## Workstream B — Packaging & build (cross-cutting)

### B1. agent_wires dev-only (Critical #4)

**Problem:** `screen_recorder/pubspec.yaml:83` hard-depends on `agent_wires_probe` at
`../../../agent-wires/...`, a sibling repo not in git. Fresh clones cannot bootstrap.

**Design:** remove the hard `path:` dependency from the committed `pubspec.yaml`. Gate the probe's
usage behind `kDebugMode` so production code paths don't reference it, and provide the dependency
via a **local-only** mechanism (a `dependency_overrides` entry in an untracked/local override file,
or a documented opt-in) so a developer who has the sibling repo can still wire it, while CI and
fresh clones build without it. Document the setup in the repo.

**Verification:** a clean checkout (without the sibling repo) runs `melos bootstrap` + `melos test`
successfully.

### B2. CI rewrite (Critical #5)

**Problem:** `.github/workflows/test-all-platforms.yml` only `flutter test`s `screen_recorder`
(engine + interface tests never run), has no `analyze` step, and pins Flutter 3.16.0 which ships a
Dart that cannot satisfy the `^3.9.2` SDK constraint.

**Design:** rewrite the workflow to install Melos, run `melos bootstrap` → `melos analyze` →
`melos test` (covering all packages). Pin a Flutter version that ships Dart ≥ 3.9 (or use
`channel: stable`). Bump `actions/checkout` to v4. Keep the macOS runner as primary; Win/Linux jobs
may run analyze/test for the packages that build there, but are not gated on app composition.

**Verification:** workflow file is internally consistent; `melos analyze`/`melos test` run locally
as a proxy for CI.

---

## Workstream C — Native macOS correctness

**Package:** `packages/screen_recorder_macos`

### C1. Data races (Major #7)

**Problem:** `VideoToolboxEncoder` counters (`VideoToolboxEncoder.swift:46-53`) are mutated from
both the capture queue and VideoToolbox's output queue; `LiveRecordingWriter.appendVideo/appendAudio`
(`LiveRecordingWriter.swift:67-71`) and `AVAssetWriterInput.append` are touched from two queues
without synchronization. These feed `NativePerfStats`.

**Design:** introduce a dedicated serial dispatch queue that owns all writer append operations
(video + audio funnel through it) and encoder counter mutations; or use atomic operations for the
plain counters. Reads for perf stats happen on the same queue (or via an atomic snapshot).

**Verification:** compile-check via `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build`
(per project memory, `flutter build macos` is broken here). Manual capture smoke-test: record, stop,
confirm A/V sync and that perf stats are sane. Native unit tests where feasible.

### C2. dartPluginClass registration (Major #11)

**Problem:** `_macos/pubspec.yaml:38` declares only the native `pluginClass`; the app compensates
with a manual `ScreenRecorderMacos.registerWith()` in `main.dart:45`. Non-idiomatic; a non-macOS
build crashes at startup.

**Design:** add `dartPluginClass: ScreenRecorderMacos` under `platforms.macos`. Remove the manual
`registerWith()` call, relying on Flutter's auto-registration. Ensure a non-macOS run degrades
gracefully (interface throws `UnimplementedError` rather than the app crashing on a hard call).

**Verification:** app launches and records on macOS without the manual call; compile-check.

---

## Workstream D — Federation

**Packages:** `screen_recorder_platform_interface`, `_windows`, `_linux` (+ verify `_macos`).

### D1. Channel-name unification (Critical #6)

**Problem:** three channel names in play — interface/macOS use
`com.slipreel.screen_recorder/recording`; Windows/Linux Dart use `…/methods`; Windows/Linux native
use `com.screenflow_studio.screen_recorder/methods`. Dart and native disagree with each other and
with the interface, so those plugins could never connect.

**Design:**
- Define all channel + event-channel names as constants in `screen_recorder_platform_interface`
  (extend `constants.dart`), including the currently-missing method constants
  (`isAccessibilityTrusted`, `requestAccessibilityPermission`, `getStockCursorImages`).
- All platform Dart implementations reference those constants.
- Windows/Linux native literals are updated to match exactly:
  `com.slipreel.screen_recorder/recording` and the agreed event-channel names.

**Tests:** a unit test in the interface asserts the constant values; per-platform Dart tests assert
they construct channels from the constants.

### D2. Document parity (Major #8)

**Design:** add a parity matrix + explicit "Windows/Linux are unimplemented placeholders" note to
the platform interface README. Update root `IMPLEMENTATION_PLAN.md` to state the project is
macOS-first and the other platforms are staged/not-integrated.

---

## Workstream E — App architecture

**Package:** `packages/screen_recorder`

### E1. Decompose playback_screen (Major #9)

**Problem:** `playback_screen.dart` (1277 lines) owns export orchestration, trim, hover-scrub,
shortcuts, zoom, and persistence — untestable and the biggest maintainability risk.

**Design:** extract three focused, injectable, unit-tested units consumed by the (now thinner)
widget:
- **`ExportService`** — takes export settings + project state (incl. the trim/speed/fade from
  Workstream A) and returns a progress stream; owns the 3-phase export orchestration and surfaces
  `FfmpegNotFoundException` (A1) as a typed failure for the UI to render.
- **`TrimController`** — trim selection + `_enforceTrimBounds` logic; this is the source of the
  `TrimSelection` that A4 threads into the pipeline.
- **`HoverScrubController`** — hover-scrub anchoring (`_intendedPosition`/`_isHovering`).

`playback_screen.dart` becomes presentation + wiring over these units.

**Tests:** unit tests for each controller/service (trim bounds enforcement, hover anchoring,
export progress + error propagation) — logic that is currently untestable inside the `State`.

### E2. Async-gap fixes (Major #12)

**Problem:** `recording_bar_screen.dart:193-208` registers `ref.listen` → async navigation and a
per-build `addPostFrameCallback` for `_syncMicMonitor` inside `build()`; `playback_screen.dart:423,590`
fire-and-forget `Process.run('open', …)` without await/catch.

**Design:**
- Move the recording→pill/panel `ref.listen` and the `_syncMicMonitor` driver out of `build()`
  into stable provider listeners (init-time or `ref.listenManual`), with a re-entrancy guard on the
  panel navigation.
- `unawaited(Process.run(...).catchError(...))` on the reveal-in-Finder calls, with a snackbar on
  failure.

**Tests:** widget/unit tests where the seams allow; verify the mic-monitor sync no longer schedules
a post-frame callback per build.

---

## Sequencing & dependencies

- **A4 (trim/speed/fade) and E1 (ExportService)** are coupled — trim/speed/fade flows
  UI → ExportService → pipeline. Do A1–A3 (resolver, lifecycle, stderr) and E1 (ExportService
  extraction) first, then A4 on top of both, then A5 (delete isolate).
- **B, C, D** are independent of A/E and of each other — they can proceed in parallel.
- **E2** is independent of E1 and can land anytime.
- Each workstream lands as its own reviewed change with green tests, following TDD per finding
  (write the failing test that encodes the finding, then fix).

## Risks

- **Trim time-base (A4):** the trim start offset must shift the cursor/zoom/scene time base so the
  deterministic focal track and cursor motion align to the trimmed output. The regression test must
  assert cursor/zoom alignment after trim, not merely output duration. This is the highest-risk
  piece.
- **Native serial queue (C1):** changes the only shipping recording path. `flutter build macos` is
  broken in this environment; compile-check via `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build`
  and verify with a manual capture (record → stop → check A/V sync + perf stats).
- **agent_wires (B1):** must confirm production code paths don't reference the probe once the hard
  dep is removed; a clean checkout must bootstrap and test green.

## Success criteria

- Fresh clone (no sibling repo) runs `melos bootstrap` + `melos analyze` + `melos test` green.
- Export honors trim, speed, and fades in MP4 and GIF, verified by tests including cursor alignment
  after trim.
- ffmpeg resolves via the resolver with a clear error when absent; no orphaned ffmpeg processes on
  failure/cancellation (test-verified).
- macOS native compiles via xcodebuild; recording path uses serialized writer/encoder access;
  plugin auto-registers via `dartPluginClass`.
- All platform channel names derive from shared constants; Win/Linux documented as placeholders.
- `playback_screen.dart` export/trim/hover logic lives in tested units.
- CI runs analyze + test across all packages on a Dart ≥ 3.9 toolchain.
