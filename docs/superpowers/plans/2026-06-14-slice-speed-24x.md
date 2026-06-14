# Slice Speed Presets up to 24× Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let editors speed up a timeline slice up to 24× (from the current 4× cap), with a logarithmic fine-tune slider and automatic, non-destructive audio muting above 4×.

**Architecture:** The export engine already speed-agnostic (`setpts=PTS/speed`, chained `atempo`, `effectiveLength/speed` duration). The work is: raise the controller clamp, add a `SpeedScale` log-mapping helper, add a derived `ClipSlice.audioSilencedBySpeed` getter, OR that into the export filter graph's `volume=0` decision and the preview volume, and rebuild the slice-editor speed UI.

**Tech Stack:** Dart / Flutter, Riverpod (`StateNotifier`), ffmpeg `filter_complex`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-06-14-slice-speed-24x-design.md`

**Conventions:**
- Engine tests run from `packages/slipreel_engine`; app tests from `packages/screen_recorder`.
- TDD: failing test → minimal code → green → commit. One logical change per commit.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `packages/slipreel_engine/lib/editor/speed_scale.dart` | Log mapping speed↔slider position + detent snapping | **Create** |
| `packages/slipreel_engine/lib/state/editor_project_controller.dart` | Raise `setSliceSpeed` clamp to 24× | Modify |
| `packages/slipreel_engine/lib/state/clip_slice.dart` | `kSpeedAudioMuteThreshold` + `audioSilencedBySpeed` getter | Modify |
| `packages/slipreel_engine/lib/export/n_slice_filter_graph.dart` | Silence speed-muted slices in the audio chain | Modify |
| `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart` | Extended chips, log slider, disabled-audio note | Modify |
| `packages/screen_recorder/lib/ui/screens/playback_screen.dart` | Preview volume mute above threshold | Modify |

---

### Task 1: `SpeedScale` log-mapping helper

**Files:**
- Create: `packages/slipreel_engine/lib/editor/speed_scale.dart`
- Test: `packages/slipreel_engine/test/editor/speed_scale_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/editor/speed_scale_test.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/speed_scale.dart';

void main() {
  test('endpoints map to the range bounds', () {
    expect(SpeedScale.speedFromPos(0), closeTo(0.25, 1e-9));
    expect(SpeedScale.speedFromPos(1), closeTo(24.0, 1e-9));
    expect(SpeedScale.posFromSpeed(0.25), closeTo(0.0, 1e-9));
    expect(SpeedScale.posFromSpeed(24.0), closeTo(1.0, 1e-9));
  });

  test('the midpoint is the geometric mean (log scale)', () {
    expect(SpeedScale.speedFromPos(0.5), closeTo(math.sqrt(0.25 * 24.0), 1e-9));
  });

  test('pos -> speed -> pos round-trips', () {
    for (final s in <double>[0.3, 1.0, 2.5, 7.0, 20.0]) {
      expect(SpeedScale.speedFromPos(SpeedScale.posFromSpeed(s)),
          closeTo(s, 1e-9));
    }
  });

  test('is monotonically increasing', () {
    expect(SpeedScale.speedFromPos(0.3),
        lessThan(SpeedScale.speedFromPos(0.7)));
  });

  test('out-of-range inputs clamp', () {
    expect(SpeedScale.speedFromPos(-1), closeTo(0.25, 1e-9));
    expect(SpeedScale.speedFromPos(2), closeTo(24.0, 1e-9));
    expect(SpeedScale.posFromSpeed(100), closeTo(1.0, 1e-9));
    expect(SpeedScale.posFromSpeed(0.01), closeTo(0.0, 1e-9));
  });

  test('snap pulls near-detent values to the detent', () {
    expect(SpeedScale.snap(1.0), 1.0);
    expect(SpeedScale.snap(2.1), 2.0);
    expect(SpeedScale.snap(0.99), 1.0);
  });

  test('snap leaves clearly-between values alone', () {
    expect(SpeedScale.snap(2.6), closeTo(2.6, 1e-9));
    expect(SpeedScale.snap(6.0), closeTo(6.0, 1e-9));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/speed_scale_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'slipreel_engine' ... speed_scale.dart` / "SpeedScale isn't defined".

- [ ] **Step 3: Write the implementation**

Create `packages/slipreel_engine/lib/editor/speed_scale.dart`:

```dart
import 'dart:math' as math;

/// Maps the slice playback-speed range [min]..[max]× onto a normalized slider
/// position 0..1 on a LOGARITHMIC scale, so each octave of speed gets equal
/// slider travel (fine control near 1× instead of a twitchy linear sweep).
///
///   speed = min · (max/min)^t            (speedFromPos)
///   t     = ln(speed/min) / ln(max/min)  (posFromSpeed)
///
/// [snap] pulls a speed to the nearest [detents] entry when it lands within
/// [posTolerance] of it in normalized space, so common values (notably exactly
/// 1×) stay reachable despite the continuous log mapping.
class SpeedScale {
  const SpeedScale._();

  static const double min = 0.25;
  static const double max = 24.0;

  /// Snap targets, ascending — the slice-editor preset chips plus the 0.25×
  /// floor.
  static const List<double> detents = <double>[
    0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 16.0, 24.0,
  ];

  static final double _lnRange = math.log(max / min);

  /// Speed for a normalized position [t] (clamped to 0..1).
  static double speedFromPos(double t) {
    final clamped = t.clamp(0.0, 1.0);
    return min * math.pow(max / min, clamped).toDouble();
  }

  /// Normalized position for a [speed] (clamped to [min]..[max]).
  static double posFromSpeed(double speed) {
    final clamped = speed.clamp(min, max);
    return math.log(clamped / min) / _lnRange;
  }

  /// Returns the nearest detent when [speed] is within [posTolerance] of one
  /// in normalized space; otherwise returns [speed] clamped to range.
  static double snap(double speed, {double posTolerance = 0.02}) {
    final clamped = speed.clamp(min, max).toDouble();
    final pos = posFromSpeed(clamped);
    double? best;
    var bestDelta = posTolerance;
    for (final d in detents) {
      final delta = (posFromSpeed(d) - pos).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = d;
      }
    }
    return best ?? clamped;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/editor/speed_scale_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/editor/speed_scale.dart packages/slipreel_engine/test/editor/speed_scale_test.dart
git commit -m "feat(speed): SpeedScale log mapping for 0.25-24x slider + detent snapping"
```

---

### Task 2: Raise the `setSliceSpeed` clamp to 24×

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart:258`
- Test: `packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart`

- [ ] **Step 1: Update the existing clamp test to expect 24×**

In `editor_project_controller_slice_test.dart`, replace the existing test (it currently asserts a `4.0` ceiling):

```dart
    test('setSliceSpeed clamps to [0.25, 4.0]', () {
      controller.setSliceSpeed(0, -1.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 0.25);
      controller.setSliceSpeed(0, 99.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 4.0);
    });
```

with:

```dart
    test('setSliceSpeed clamps to [0.25, 24.0]', () {
      controller.setSliceSpeed(0, -1.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 0.25);
      controller.setSliceSpeed(0, 99.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 24.0);
      controller.setSliceSpeed(0, 8.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 8.0);
    });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_controller_slice_test.dart -p vm --name "clamps to"`
Expected: FAIL — `Expected: <24.0> Actual: <4.0>`.

- [ ] **Step 3: Raise the clamp**

In `editor_project_controller.dart`, in `setSliceSpeed`, change line 258:

```dart
    final clamped = speed.clamp(0.25, 4.0);
```

to:

```dart
    final clamped = speed.clamp(0.25, 24.0);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_controller_slice_test.dart`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart
git commit -m "feat(speed): raise per-slice speed clamp ceiling to 24x"
```

---

### Task 3: `kSpeedAudioMuteThreshold` + `ClipSlice.audioSilencedBySpeed`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/clip_slice.dart`
- Test: `packages/slipreel_engine/test/state/clip_slice_test.dart`

- [ ] **Step 1: Write the failing test**

Append to `packages/slipreel_engine/test/state/clip_slice_test.dart` (inside `main()`):

```dart
  group('audioSilencedBySpeed', () {
    ClipSlice slice(double speed) => ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 5),
          playbackSpeed: speed,
        );

    test('is false at or below the threshold', () {
      expect(slice(1.0).audioSilencedBySpeed, isFalse);
      expect(slice(4.0).audioSilencedBySpeed, isFalse);
    });

    test('is true above the threshold', () {
      expect(slice(4.01).audioSilencedBySpeed, isTrue);
      expect(slice(8.0).audioSilencedBySpeed, isTrue);
      expect(slice(24.0).audioSilencedBySpeed, isTrue);
    });

    test('the threshold constant is 4x', () {
      expect(kSpeedAudioMuteThreshold, 4.0);
    });
  });
```

If `clip_slice_test.dart` does not already import the library, ensure this import is present at the top of the file:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/clip_slice_test.dart`
Expected: FAIL — "The getter 'audioSilencedBySpeed' isn't defined" / "kSpeedAudioMuteThreshold isn't defined".

- [ ] **Step 3: Add the constant and getter**

In `clip_slice.dart`, add the top-level constant just above the `class ClipSlice` declaration:

```dart
/// Slices sped past this factor have their audio auto-silenced in export and
/// preview — sped-up audio above ~4× is unusable (chipmunk noise). The mute is
/// DERIVED from speed (see [ClipSlice.audioSilencedBySpeed]); it never touches
/// the user's micMuted/systemMuted flags.
const double kSpeedAudioMuteThreshold = 4.0;
```

Then add this getter inside `class ClipSlice` (next to the other getters such as `effectiveLength` / `trimmedDuration`):

```dart
  /// Whether this slice's audio should be dropped purely because it is sped up
  /// past [kSpeedAudioMuteThreshold]. Non-destructive: lowering the speed back
  /// to ≤ the threshold restores audio.
  bool get audioSilencedBySpeed => playbackSpeed > kSpeedAudioMuteThreshold;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/state/clip_slice_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/clip_slice.dart packages/slipreel_engine/test/state/clip_slice_test.dart
git commit -m "feat(speed): kSpeedAudioMuteThreshold + ClipSlice.audioSilencedBySpeed (derived)"
```

---

### Task 4: Silence speed-muted slices in the export filter graph

**Files:**
- Modify: `packages/slipreel_engine/lib/export/n_slice_filter_graph.dart:244`
- Test: `packages/slipreel_engine/test/export/n_slice_filter_graph_speed_mute_test.dart` (create)

Background: `_audioChainFor` builds `atrim,asetpts,atempo,volume=…,aformat,afade` per slice. Muting is `volume=0` AFTER the `atempo`, so a silenced slice keeps its sped-up duration and the per-track `concat` stays aligned with the video concat. We OR `audioSilencedBySpeed` into that `volume=0` decision.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/export/n_slice_filter_graph_speed_mute_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWith(ClipSlice slice) =>
    EditorProjectState.defaults().copyWith(
      timeline: const Timeline(zoomTracks: []).copyWith(clips: [slice]),
    );

// A single mono source stream (one audio track).
List<AudioStreamInfo> _oneStream() => const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
    ];

ClipSlice _slice(double speed) => ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(seconds: 10),
      playbackSpeed: speed,
    );

void main() {
  test('a slice sped past the threshold emits silent audio (volume=0) but '
      'keeps its atempo so the track duration stays aligned', () {
    final graph = buildExportFilterGraph(
      state: _stateWith(_slice(8.0)),
      audioStreams: _oneStream(),
    );
    expect(graph.filterComplex, contains('volume=0'));
    expect(graph.filterComplex, contains('atempo='),
        reason: 'the silent audio must still be sped up to match the video');
  });

  test('a slice at the threshold keeps full-gain audio', () {
    final graph = buildExportFilterGraph(
      state: _stateWith(_slice(4.0)),
      audioStreams: _oneStream(),
    );
    expect(graph.filterComplex, contains('volume=1.0'));
    expect(graph.filterComplex, isNot(contains('volume=0')));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/n_slice_filter_graph_speed_mute_test.dart`
Expected: FAIL — the 8× case still produces `volume=1.0` (audio not silenced), so `contains('volume=0')` fails.

- [ ] **Step 3: OR `audioSilencedBySpeed` into the volume decision**

In `n_slice_filter_graph.dart`, inside `_audioChainFor`, change:

```dart
  // Muted ⇒ volume=0; otherwise gain percent as fraction.
  final volume = muted ? 0.0 : gainPercent / 100.0;
```

to:

```dart
  // volume=0 when the user muted the track OR the slice is sped past the
  // auto-mute threshold (audioSilencedBySpeed). The atempo above still runs so
  // the silent audio keeps the slice's sped-up duration and the per-track
  // concat stays aligned with the video concat.
  final volume = (muted || s.audioSilencedBySpeed) ? 0.0 : gainPercent / 100.0;
```

(`s` is the `ClipSlice` parameter already passed into `_audioChainFor`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/n_slice_filter_graph_speed_mute_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the existing export suite to confirm no regressions**

Run: `cd packages/slipreel_engine && flutter test test/export/`
Expected: PASS (all export tests, including `export_pipeline_multi_slice_test.dart`).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/export/n_slice_filter_graph.dart packages/slipreel_engine/test/export/n_slice_filter_graph_speed_mute_test.dart
git commit -m "feat(speed): silence slices sped past the auto-mute threshold in export"
```

---

### Task 5: Slice-editor UI — extended chips, log slider, disabled-audio note

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart`

- [ ] **Step 1: Write the failing widget tests**

Append to `slice_editor_test.dart` (inside `main()`; the file already defines `_host`, `_stateWithOneSlice`):

```dart
  testWidgets('shows the extended speed presets up to 24x', (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice()));
    expect(find.text('4x'), findsOneWidget);
    expect(find.text('8x'), findsOneWidget);
    expect(find.text('16x'), findsOneWidget);
    expect(find.text('24x'), findsOneWidget);
  });

  testWidgets('tapping the 8x chip sets the slice speed to 8x', (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice()));
    await tester.tap(find.text('8x'));
    await tester.pump();
    expect(find.text('Final speed: 800%'), findsOneWidget);
  });

  testWidgets('above the threshold the audio rows are replaced by a note',
      (tester) async {
    await tester.pumpWidget(_host(
      initial: _stateWithOneSlice(
        slice: ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          playbackSpeed: 8.0,
        ),
      ),
    ));
    expect(find.text('Muted above 4x'), findsOneWidget);
    expect(find.text('Mic'), findsNothing);
    expect(find.text('System'), findsNothing);
  });
```

Ensure the test file imports `ClipSlice` (it already imports `package:slipreel_engine/state/clip_slice.dart` per the existing harness).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/contexts/slice_editor_test.dart`
Expected: FAIL — `find.text('4x')` etc. find nothing (presets stop at 2x); `'Muted above 4x'` not found.

- [ ] **Step 3: Add imports**

At the top of `slice_editor.dart`, add:

```dart
import 'package:slipreel_engine/editor/speed_scale.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
```

- [ ] **Step 4: Extend the preset list**

Change:

```dart
  static const _speedPresets = <double>[0.5, 1.0, 1.5, 2.0];
```

to:

```dart
  static const _speedPresets = <double>[
    0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 16.0, 24.0,
  ];
```

- [ ] **Step 5: Convert the fine-tune slider to the log scale**

Replace the existing `InspectorSlider(...)` for "Fine-tune":

```dart
                InspectorSlider(
                  label: 'Fine-tune',
                  // Percent format so this row doesn't echo the "1.5"
                  // substring used by the preset chip labels.
                  subtitle:
                      'Final speed: ${(clip.playbackSpeed * 100).round()}%',
                  value: clip.playbackSpeed,
                  min: 0.25,
                  max: 4.0,
                  onChanged: (v) => notifier.setSliceSpeed(sliceIndex, v),
                  onReset: () => notifier.setSliceSpeed(sliceIndex, 1.0),
                  canReset: clip.playbackSpeed != 1.0,
                ),
```

with (slider now operates on the normalized 0..1 log position; snap keeps detents reachable):

```dart
                InspectorSlider(
                  label: 'Fine-tune',
                  subtitle:
                      'Final speed: ${(clip.playbackSpeed * 100).round()}%',
                  value: SpeedScale.posFromSpeed(clip.playbackSpeed),
                  min: 0.0,
                  max: 1.0,
                  onChanged: (t) => notifier.setSliceSpeed(
                    sliceIndex,
                    SpeedScale.snap(SpeedScale.speedFromPos(t)),
                  ),
                  onReset: () => notifier.setSliceSpeed(sliceIndex, 1.0),
                  canReset: clip.playbackSpeed != 1.0,
                ),
```

- [ ] **Step 6: Replace the Audio rows with a note when speed-muted**

Find the Audio section (the `InspectorSectionLabel('Audio')` followed by the two `_GainRow`s for Mic and System). Replace the `_GainRow` block so it is conditional on `clip.audioSilencedBySpeed`. The resulting structure:

```dart
                const InspectorSectionDivider(),
                const InspectorSectionLabel('Audio'),
                if (clip.audioSilencedBySpeed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'Muted above '
                      '${kSpeedAudioMuteThreshold.toStringAsFixed(0)}x',
                      style: const TextStyle(
                          color: kInspectorMuted, fontSize: 12),
                    ),
                  )
                else ...[
                  _GainRow(
                    label: 'Mic',
                    percent: clip.micGainPercent,
                    muted: clip.micMuted,
                    onPercentChanged: (v) =>
                        notifier.setSliceMicGain(sliceIndex, v),
                    onMutedChanged: (v) =>
                        notifier.setSliceMicMuted(sliceIndex, v),
                  ),
                  const SizedBox(height: 12),
                  _GainRow(
                    label: 'System',
                    percent: clip.systemGainPercent,
                    muted: clip.systemMuted,
                    onPercentChanged: (v) =>
                        notifier.setSliceSystemGain(sliceIndex, v),
                    onMutedChanged: (v) =>
                        notifier.setSliceSystemMuted(sliceIndex, v),
                  ),
                ],
```

(`kInspectorMuted` is already used elsewhere in this file via the `inspector_widgets.dart` import.)

- [ ] **Step 7: Run the widget tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/contexts/slice_editor_test.dart`
Expected: PASS (existing tests + the 3 new ones).

- [ ] **Step 8: Analyze for unused imports / lints**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/inspector/contexts/slice_editor.dart`
Expected: "No issues found!"

- [ ] **Step 9: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart
git commit -m "feat(speed): extended speed chips to 24x + log fine-tune slider + muted-audio note"
```

---

### Task 6: Preview — mute audio above the threshold

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (`_applyEffectivePlaybackSpeed`, ~line 538; add a top-level helper near the other speed helpers ~line 174)
- Test: `packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart`

- [ ] **Step 1: Write the failing test**

Append to `playback_screen_slice_speed_test.dart` (inside `main()`):

```dart
  test('previewVolumeForSpeed silences audio above the threshold', () {
    expect(previewVolumeForSpeed(1.0), 1.0);
    expect(previewVolumeForSpeed(4.0), 1.0);
    expect(previewVolumeForSpeed(8.0), 0.0);
    expect(previewVolumeForSpeed(24.0), 0.0);
  });
```

The file already imports `package:screen_recorder/ui/screens/playback_screen.dart` (it tests `effectiveClipSpeedAt` from there). If it does not, add that import.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback_screen_slice_speed_test.dart`
Expected: FAIL — "The function 'previewVolumeForSpeed' isn't defined".

- [ ] **Step 3: Add the helper and apply it**

In `playback_screen.dart`, add the import if not already present:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

Add this top-level function near the other pure speed helpers (e.g. just below `effectiveClipSpeedAt` / `clipSpeedAt`, around line 188):

```dart
/// Preview audio volume for a slice playing at [clipSpeed]: silenced above the
/// auto-mute threshold (matching the export filter graph), full otherwise.
double previewVolumeForSpeed(double clipSpeed) =>
    clipSpeed > kSpeedAudioMuteThreshold ? 0.0 : 1.0;
```

Then in `_applyEffectivePlaybackSpeed`, after the existing `_controller.setPlaybackSpeed(effective);`, add the volume line:

```dart
  void _applyEffectivePlaybackSpeed(double clipSpeed) {
    if (!_isInitialized) return;
    _lastClipSpeedApplied = clipSpeed;
    final effective = effectivePreviewRate(clipSpeed, _previewPlaybackSpeed);
    // VideoPlayerController.setPlaybackSpeed clamps to a non-zero,
    // non-negative value; guard against degenerate inputs.
    if (effective <= 0) return;
    _controller.setPlaybackSpeed(effective);
    // Match the export: drop preview audio for slices sped past the threshold.
    _controller.setVolume(previewVolumeForSpeed(clipSpeed));
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback_screen_slice_speed_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/playback_screen.dart`
Expected: "No issues found!" (or only pre-existing infos unrelated to this change).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart
git commit -m "feat(speed): mute preview audio for slices sped past the threshold"
```

---

### Task 7: Full-suite verification

- [ ] **Step 1: Run both package suites**

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS (all engine tests).

Run: `cd packages/screen_recorder && flutter test`
Expected: PASS (all app tests).

- [ ] **Step 2: If green, the feature is complete.** No commit (verification only). Hand back for review / merge.

---

## Notes / out of scope (from the spec)

- No JSON migration: `playbackSpeed` is already a stored double in range.
- Preview at very high speeds may stutter (AVPlayer); the exact result is the export. No special handling beyond the volume mute.
- The global recording-audio control (`setAll*`) is unrelated to this per-slice speed mute.
