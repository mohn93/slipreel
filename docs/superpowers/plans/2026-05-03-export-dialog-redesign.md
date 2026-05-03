# Export Dialog Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the radio-list `ExportDialog` with a Screen-Studio-style dialog that lets users pick **format**, **frame rate**, **resolution**, **compression**, and **destination** as independent axes — matching the mockups in the user's request screenshots verbatim.

**Architecture:** A value-class `ExportSettings` holds the five axis choices (plus optional title / private toggle). A `compressionBitrate(resolution, tier)` table converts compression × resolution to `bitrateKbps` for the existing `FfmpegEncoder`. A new pluggable `videoEncoder` vs `gifEncoder` lets the same compositor feed either an MP4 pipeline (existing) or a GIF pipeline (palettegen + paletteuse, two-pass). Three destination handlers (`FileSaver`, `ClipboardCopier`, `ShareableLinkPublisher`) own the post-encode delivery, with `ShareableLinkPublisher` stubbed to copy a `file://` URL for now (per scoping decision: option 2 — UI complete, no backend yet).

**Tech Stack:**
- Flutter / Dart 3 (existing)
- Two new pubspec deps: `file_selector` (Save-as dialog), `super_clipboard` (file-URL clipboard on macOS)
- `path_provider` (already present) for the persisted-settings sidecar
- ffmpeg CLI (existing) — GIF pipeline reuses it

---

## File Structure

**New:**
- `lib/models/export_settings.dart` — value class, enums (`ExportFormat`, `ExportFrameRate`, `ExportResolution`, `CompressionTier`, `ExportDestination`), JSON codec
- `lib/models/compression_bitrate.dart` — `compressionBitrate(resolution, tier) → kbps` lookup + GIF tier knobs (`max_colors`, `dither`)
- `lib/state/export_settings_store.dart` — load/save last-used `ExportSettings` to a single app-level json file under `getApplicationSupportDirectory()`
- `lib/export/gif_export_pipeline.dart` — two-pass palette pipeline, parallel structure to `ExportPipeline`
- `lib/export/export_estimator.dart` — time + size estimates (duration × bitrate, duration / realtime-multiplier)
- `lib/ui/widgets/export_dialog/export_dialog.dart` — new dialog widget (top-level)
- `lib/ui/widgets/export_dialog/format_picker.dart` — MP4 / GIF segmented control
- `lib/ui/widgets/export_dialog/frame_rate_picker.dart` — dropdown w/ static list `[60,50,30,25,24,20,10]`
- `lib/ui/widgets/export_dialog/resolution_picker.dart` — 720p/1080p/4K segmented; 4K disabled when source < 4K
- `lib/ui/widgets/export_dialog/compression_picker.dart` — Studio/Social/Web/Web (Low) segmented + description
- `lib/ui/widgets/export_dialog/destination_picker.dart` — File/Clipboard/Shareable link segmented
- `lib/ui/widgets/export_dialog/shareable_link_panel.dart` — title field + private toggle (only shown when destination=link)
- `lib/ui/widgets/export_dialog/estimation_line.dart` — "Estimation — Export time Xs — Output size YMB"
- `lib/services/destination_handlers.dart` — `FileSaver`, `ClipboardCopier`, `ShareableLinkPublisher`

**Modify:**
- `lib/models/export_preset.dart` — keep as a thin derived view from `ExportSettings`, or delete entirely once callers migrate. Plan deletes after Task 5.
- `lib/ui/screens/playback_screen.dart` — replace export-button handler to use new dialog + new pipeline picker
- `lib/export/export_pipeline.dart` — accept an `ExportSettings` so MP4 path doesn't need to know about resolution/tier resolution
- `packages/screen_recorder/pubspec.yaml` — add `file_selector`, `super_clipboard`

---

## Compression Bitrate Table (locked)

| | Studio | Social Media | Web | Web (Low) |
|---|---|---|---|---|
| **720p** | 8 Mbps | 5 Mbps | 3 Mbps | 1.5 Mbps |
| **1080p** | 16 Mbps | 10 Mbps | 6 Mbps | 3 Mbps |
| **4K** | 50 Mbps | 32 Mbps | 20 Mbps | 10 Mbps |

GIF tiers (per resolution × tier, all GIF):

| Tier | max_colors | dither |
|---|---|---|
| Studio | 256 | sierra2_4a |
| Social Media | 192 | sierra2_4a |
| Web | 128 | bayer:bayer_scale=3 |
| Web (Low) | 64 | none |

Description strings (verbatim from mockup, shown beneath the picker):
- **Studio**: "Highest quality. Best for archival or further editing."
- **Social Media**: "Optimized for Twitter, LinkedIn, and similar uploads."
- **Web**: "Good for directly playing on websites. Compression is slightly visible, but not distracting."
- **Web (Low)**: "Aggressive compression. Smaller files, more visible artifacts."

Subtitle (under all tiers): "Quality setting does not impact export speed."

---

## Behavior Rules (locked)

1. **4K disabled when source < 4K.** Greyed button, tooltip "Source resolution is lower than 4K".
2. **Shareable link locks resolution and fps** to 1080p / 60fps (mockup footer text shown verbatim: "Shareable links are always exported as 1080p video at 60fps.").
3. **Frame rate options**: `[60, 50, 30, 25, 24, 20, 10]`. Default 30 for MP4, 10 for GIF.
4. **Default settings on first open**: Format=MP4, Resolution=1080p (capped to source if smaller), Compression=Web, FPS=30, Destination=File.
5. **Persistence**: each successful export writes the `ExportSettings` (minus title) to `<appSupport>/export_settings.json`. Next open reads it.
6. **Resolution sub-label**: "1428px × 1080px" computed as `roundEvenSourceAspectFitted(targetHeight)` shown under the resolution picker.
7. **Estimation line**:
   - Time = `duration / lastKnownRealtimeMultiplier` (read from latest perf summary, default 0.7×). "Estimation — Export time 1 second"
   - Size = `duration × bitrate / 8` for MP4; for GIF use a calibration constant (TBD by measurement during Task 6).
8. **Clipboard destination**: writes the file to a tmp path and copies its file URL to NSPasteboard via `super_clipboard`. Shows a "📁 Reveal in Finder" button (the folder icon in image #36) post-export.
9. **Shareable link destination (stub)**: same as Clipboard but copies `file://<absolute-path>` to clipboard and shows a snackbar "URL copied (local file for now)".
10. **GIF format**: hides Compression picker description that's MP4-specific; uses the GIF tier knobs above. Two-pass ffmpeg.

---

## Tasks

### Task 1: Domain model + bitrate table

**Files:**
- Create: `lib/models/export_settings.dart`
- Create: `lib/models/compression_bitrate.dart`
- Create: `test/models/export_settings_test.dart`
- Create: `test/models/compression_bitrate_test.dart`

- [ ] **Step 1: Failing test for `ExportSettings.defaults()`**

```dart
// test/models/export_settings_test.dart
test('defaults are MP4 / 1080p / Web / 30fps / File / no title / not private', () {
  final s = ExportSettings.defaults();
  expect(s.format, ExportFormat.mp4);
  expect(s.resolution, ExportResolution.r1080p);
  expect(s.compression, CompressionTier.web);
  expect(s.frameRate, 30);
  expect(s.destination, ExportDestination.file);
  expect(s.title, isNull);
  expect(s.isPrivate, isFalse);
});
```

- [ ] **Step 2: Implement enums + value class**

```dart
// lib/models/export_settings.dart
enum ExportFormat { mp4, gif }
enum ExportResolution { r720p, r1080p, r4k }
enum CompressionTier { studio, socialMedia, web, webLow }
enum ExportDestination { file, clipboard, shareableLink }

const kFrameRateOptions = [60, 50, 30, 25, 24, 20, 10];

class ExportSettings {
  const ExportSettings({
    required this.format,
    required this.resolution,
    required this.compression,
    required this.frameRate,
    required this.destination,
    this.title,
    this.isPrivate = false,
  });

  final ExportFormat format;
  final ExportResolution resolution;
  final CompressionTier compression;
  final int frameRate;
  final ExportDestination destination;
  final String? title;
  final bool isPrivate;

  factory ExportSettings.defaults() => const ExportSettings(
    format: ExportFormat.mp4,
    resolution: ExportResolution.r1080p,
    compression: CompressionTier.web,
    frameRate: 30,
    destination: ExportDestination.file,
  );

  // Constructor signature for copyWith with explicit-clear semantics
  // for nullable title (sentinel pattern).
  ExportSettings copyWith({...});

  Map<String, dynamic> toJson();
  factory ExportSettings.fromJson(Map<String, dynamic> json);
}
```

- [ ] **Step 3: JSON round-trip test + impl**

Round-trip every enum value; unknown enum values throw `FormatException`.

- [ ] **Step 4: Failing test for `compressionBitrate`**

```dart
test('1080p × Web is 6 Mbps', () {
  expect(
    compressionBitrate(ExportResolution.r1080p, CompressionTier.web),
    6000,
  );
});
test('4K × Studio is 50 Mbps', () {
  expect(
    compressionBitrate(ExportResolution.r4k, CompressionTier.studio),
    50000,
  );
});
```

- [ ] **Step 5: Implement table** as a `const Map` keyed on `(ExportResolution, CompressionTier)` records. Add `gifPaletteSettings(tier) → ({int maxColors, String dither})`.

- [ ] **Step 6: Helper extensions**

`ExportResolution.dimensionsFor(Size sourceVideo) → Size` — returns even-rounded target dims that fit the source's aspect into the resolution's *height* (height-bound; matches the mockup's "1428px × 1080px"). `r720p → height 720`, `r1080p → height 1080`, `r4k → height 2160`.

- [ ] **Step 7: Commit**

```
git add lib/models/export_settings.dart lib/models/compression_bitrate.dart test/models/export_settings_test.dart test/models/compression_bitrate_test.dart
git commit -m "feat(export): export settings value class + compression bitrate table"
```

---

### Task 2: Persistence (`ExportSettingsStore`)

**Files:**
- Create: `lib/state/export_settings_store.dart`
- Create: `test/state/export_settings_store_test.dart`

Mirrors the structure of `lib/state/editor_project_store.dart` (atomic write tmp-then-rename, mutation queue, schema versioning, FormatException on unknown future versions, default fallback on corrupt).

- [ ] **Step 1: Failing test — load returns defaults when file missing**

```dart
test('load returns defaults when no file exists', () async {
  final dir = Directory.systemTemp.createTempSync('exp_settings');
  final store = ExportSettingsStore(filePath: '${dir.path}/settings.json');
  expect(await store.load(), ExportSettings.defaults());
});
```

- [ ] **Step 2: Failing test — save then load round-trips**
- [ ] **Step 3: Failing test — corrupt JSON → defaults + warning logged**
- [ ] **Step 4: Failing test — concurrent saves are serialized (mutation queue)**

- [ ] **Step 5: Implement** following `editor_project_store.dart` pattern. Path resolved at construction via `getApplicationSupportDirectory()` for production; injected for tests.

- [ ] **Step 6: Commit**

```
git commit -m "feat(export): persist last-used settings via app-level sidecar json"
```

---

### Task 3: GIF export pipeline

**Files:**
- Create: `lib/export/gif_export_pipeline.dart`
- Create: `test/export/gif_export_pipeline_test.dart`

The pipeline takes the same RGBA frames from `FrameCompositor`, writes them through ffmpeg twice:

1. Pass 1: `ffmpeg -f rawvideo -pix_fmt rgba -s WxH -r N -i - -vf "palettegen=max_colors=C:stats_mode=full" palette.png`
2. Pass 2: `ffmpeg -f rawvideo -pix_fmt rgba -s WxH -r N -i - -i palette.png -lavfi "[0:v][1:v]paletteuse=dither=D" out.gif`

Implementation: stash composed frames in a temp lossless intermediate (raw rgba file or h264 lossless mp4) on first pass through compositor, then run both ffmpeg passes against that intermediate. Reuses `FrameCompositor` exactly (preview parity). Tradeoff: 2× disk I/O during export. Acceptable for GIF use case; users export GIFs of short clips.

- [ ] **Step 1: Failing test — produces a non-empty .gif on the test fixture**
- [ ] **Step 2: Failing test — emits `onProgress` for both passes**
- [ ] **Step 3: Implementation**
- [ ] **Step 4: Commit**

```
git commit -m "feat(export): GIF pipeline with palettegen + paletteuse"
```

---

### Task 4: Estimation helper

**Files:**
- Create: `lib/export/export_estimator.dart`
- Create: `test/export/export_estimator_test.dart`

```dart
class ExportEstimator {
  ExportEstimator({this.lastRealtimeMultiplier = 0.7});
  final double lastRealtimeMultiplier;

  /// Wall-clock seconds to encode `durationSec` at `bitrateKbps`.
  Duration estimateExportTime(double durationSec);

  /// Bytes — `bitrateKbps * durationSec / 8 * 1024` for MP4;
  /// for GIF, applies a calibration factor (start at 0.6 — empirical;
  /// refine after Task 3 ships).
  int estimateOutputBytes({
    required double durationSec,
    required int bitrateKbps,
    required ExportFormat format,
  });

  String formatLine({required double durationSec, required int bitrateKbps, required ExportFormat format});
}
```

- [ ] **Step 1: Failing tests for both methods**
- [ ] **Step 2: Impl + commit**

```
git commit -m "feat(export): time + size estimation helper"
```

---

### Task 5: Pipeline integration — accept `ExportSettings`

**Files:**
- Modify: `lib/export/export_pipeline.dart`
- Modify: `test/export/export_pipeline_test.dart`

`ExportPipeline.run(settings: ExportSettings, …)` resolves bitrate via `compressionBitrate`, output dims via `ExportResolution.dimensionsFor(sourceVideoSize)`, fps via `settings.frameRate`. The old `outputWidth/Height/Fps/bitrateKbps` constructor params go away. Keep the parallel pipeline scaffolding intact.

- [ ] **Step 1: Update test to pass `ExportSettings.defaults()`**
- [ ] **Step 2: Refactor pipeline; old preset class becomes deprecated**
- [ ] **Step 3: Verify pipeline test still passes**
- [ ] **Step 4: Commit**

```
git commit -m "refactor(export): pipeline takes ExportSettings instead of raw preset fields"
```

---

### Task 6: Destination handlers

**Files:**
- Create: `lib/services/destination_handlers.dart`
- Create: `test/services/destination_handlers_test.dart`
- Modify: `pubspec.yaml` — add `file_selector: ^1.0.3`, `super_clipboard: ^0.8.20`

Three classes implementing a common `DestinationHandler` interface:

```dart
abstract class DestinationHandler {
  /// Called *before* export — gives the handler a chance to prompt the
  /// user (e.g. Save As dialog) and resolve the final output path.
  /// Returns null if user cancelled.
  Future<String?> resolveOutputPath({required String suggestedFileName});

  /// Called *after* export with the produced file path.
  /// Performs the destination-specific delivery (reveal, copy, upload).
  Future<DestinationResult> deliver(String outputPath);
}

class FileSaver implements DestinationHandler { ... }
class ClipboardCopier implements DestinationHandler { ... }
class ShareableLinkPublisher implements DestinationHandler { ... }
```

- **`FileSaver.resolveOutputPath`**: opens `file_selector` Save dialog with `suggestedFileName`. `deliver`: shows snackbar with reveal-in-finder.
- **`ClipboardCopier.resolveOutputPath`**: returns a tmp path under `getTemporaryDirectory()`. `deliver`: copies file URL to clipboard via `super_clipboard`, returns `DestinationResult` with `revealPath` set so caller shows folder icon button.
- **`ShareableLinkPublisher.resolveOutputPath`**: tmp path, settings forced to 1080p / 60fps before pipeline runs. `deliver`: copies `file://<absolute>` text to clipboard via system `Clipboard.setData`, snackbar with "URL copied (local for now)".

- [ ] **Step 1: Failing tests with mocked clipboard / file picker**
- [ ] **Step 2: Implementation**
- [ ] **Step 3: Commit**

```
git commit -m "feat(export): destination handlers for file / clipboard / link"
```

---

### Task 7: New `ExportDialog` widget — pickers

Build the dialog atomically — five children, no skeleton phase. Each picker is its own widget that takes a current value + `onChanged` callback. Parent dialog owns `ExportSettings` state.

**Files:**
- Create: `lib/ui/widgets/export_dialog/format_picker.dart`
- Create: `lib/ui/widgets/export_dialog/frame_rate_picker.dart`
- Create: `lib/ui/widgets/export_dialog/resolution_picker.dart`
- Create: `lib/ui/widgets/export_dialog/compression_picker.dart`
- Create: `lib/ui/widgets/export_dialog/destination_picker.dart`
- Create: `lib/ui/widgets/export_dialog/shareable_link_panel.dart`
- Create: `lib/ui/widgets/export_dialog/estimation_line.dart`
- Create: `lib/ui/widgets/export_dialog/segmented_button.dart` — local atom (white border on selected, transparent fill, purple `0xFF8B5CF6` accent)
- Create matching `test/ui/widgets/export_dialog/*_test.dart` for each picker

Visual conventions (read off mockups):
- Background: `0xFF0E0E10`
- Selected button border: `0xFF8B5CF6` 1.5px + `0xFF1F1A2E` fill
- Unselected button: `0xFF22232C` fill, no border
- Disabled: 40% opacity
- Title text: `0xFFE8E8EA`, 13pt 500w
- Subtitle / description: `0xFF8C8C95`, 12pt
- Section icon: 14×14, stroke-only, label same row

Each picker test: renders all options, selecting fires callback with right value, disabled options don't fire.

- [ ] **Step 1: Build `segmented_button.dart` with golden-style widget test**
- [ ] **Step 2: For each picker — failing test, then impl, commit per picker**

(Seven commits total — one per picker file. Granular commits make review easier and let the agentic worker take small reviewable bites.)

---

### Task 8: Compose `ExportDialog`

**Files:**
- Create: `lib/ui/widgets/export_dialog/export_dialog.dart`
- Create: `test/ui/widgets/export_dialog/export_dialog_test.dart`

State held in a `_ExportDialogState`:
- `ExportSettings _settings` (loaded from `ExportSettingsStore`)
- `Size? _sourceVideoSize` (from constructor — drives 4K disable + resolution sub-label)
- `Duration _videoDuration` (constructor — drives estimation)

Layout matches mockup:
1. Top row: Format (left) + Frame rate (right), aligned by section header.
2. Mid row: Resolution (left, with px sub-label) + Compression (right, with description + "Quality setting does not impact export speed" footer).
3. Bottom row: Destination (left) + primary "Export to X..." button (right purple) + Cancel (right outlined).
4. Below bottom row: Estimation line (right-aligned).
5. When destination=Shareable link: replace mid row with `ShareableLinkPanel` (title + private toggle), show "Shareable links are always exported as 1080p video at 60fps." footer instead of estimation alone.

State-derived behaviors:
- 4K disabled when `_sourceVideoSize.shortestSide < 2160`.
- Format=GIF reduces frame rate options to `[30, 25, 24, 20, 15, 10]` (drop 60/50). Default fps switches to 10.
- Destination=Shareable link forces `settings.resolution=r1080p, frameRate=60`, hides resolution/fps/compression pickers, shows title + private.
- Primary button label: "Export to file…" / "Export to clipboard" / "Export & Share" (matches mockup verbatim).

Tests cover state derivation and the shareable-link mode-switch.

- [ ] **Step 1: Failing test — default state matches mockup layout**
- [ ] **Step 2: Failing test — switching to Shareable link locks resolution + fps and reveals title field**
- [ ] **Step 3: Failing test — 4K disabled when source is 1080p**
- [ ] **Step 4: Failing test — primary button label tracks destination**
- [ ] **Step 5: Implementation**
- [ ] **Step 6: Commit**

```
git commit -m "feat(export): new ExportDialog matching Screen Studio reference"
```

---

### Task 9: Wire dialog to playback screen

**Files:**
- Modify: `lib/ui/screens/playback_screen.dart`
- Delete: `lib/models/export_preset.dart` (and any tests referencing it)

`_export()` becomes:
1. `await ExportSettingsStore.instance.load()` for defaults.
2. `showDialog<ExportSettings?>` with the new dialog. Returns null on cancel.
3. Resolve `DestinationHandler` from `settings.destination`.
4. `outputPath = await handler.resolveOutputPath(suggestedFileName: ...)` — bail if null.
5. Pick pipeline: MP4 → existing `ExportPipeline.run(settings: settings, ...)`; GIF → `GifExportPipeline.run(settings: settings, ...)`.
6. Run pipeline with progress dialog (reuse existing dialog from prior commit).
7. `await handler.deliver(outputPath)` for the post-export step.
8. `await ExportSettingsStore.instance.save(settings.copyWith(title: null))` (don't persist video title).

- [ ] **Step 1: Failing widget test — tapping Export opens new dialog**
- [ ] **Step 2: Implementation**
- [ ] **Step 3: Delete `export_preset.dart` and any references**
- [ ] **Step 4: Run full suite, verify analyzer clean**
- [ ] **Step 5: Commit**

```
git commit -m "feat(export): wire new dialog + destination handlers into playback screen"
```

---

### Task 10: Manual QA pass

Not committable, but worth a checklist run before declaring done:
- [ ] MP4 1080p Web / File works (golden path).
- [ ] MP4 4K disabled when source is < 4K.
- [ ] MP4 60fps export plays smoothly (regression check on the recent jitter fix).
- [ ] GIF Web export looks reasonable on a 5s clip.
- [ ] Clipboard mode pastes the file into Finder (verifies file URL clipboard).
- [ ] Shareable link mode shows the title + private fields, locks resolution/fps, copies a `file://` URL on click.
- [ ] Estimation line updates as resolution/compression change.
- [ ] Settings persist across an app restart.

---

## Self-Review

**Spec coverage** — every mockup state has a task:
- Default state → Tasks 7+8 (pickers + dialog).
- FPS dropdown open → frame_rate_picker (Task 7).
- Clipboard mode (folder icon button) → destination_picker (Task 7) + ClipboardCopier delivery (Task 6).
- Shareable link mode (title + private + locked-output footer) → shareable_link_panel + dialog state derivation (Task 8).
- Estimation line → estimator (Task 4) + estimation_line widget (Task 7).

**Placeholder check**: bitrate table is concrete numbers; description strings are quoted verbatim; default behavior rules are numbered and specific.

**Type consistency**: `ExportSettings` is referenced uniformly across tasks 1, 2, 5, 6, 7, 8, 9. `ExportFormat`, `ExportResolution`, `CompressionTier`, `ExportDestination` enum names match across all task descriptions.

**Open small risks (not blockers, just flag for the implementer):**
- `super_clipboard` macOS support is good but the package is reasonably new — if it fails to copy a file URL, fall back to copying the absolute path as text (matches the Shareable-link stub anyway).
- ffmpeg's GIF palette pipeline can OOM on very long clips (multi-minute). For first ship, reject GIF export of clips > 60s with a snackbar; refine later.
