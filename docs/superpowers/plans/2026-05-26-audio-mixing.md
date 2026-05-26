# Editor Audio Mixing + Export Downmix (Sub-project 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-track (mic/system) volume + mute controls in the editor and bake the mix into the export via an ffmpeg `amix` downmix to one AAC track.

**Architecture:** Per-track gains live in `EditorProjectState.audioMix` (schema v4). At export, the source's audio streams are probed, roles inferred (mic=mono, system=stereo), and a pure `buildAudioMixArgs` turns probe+gains into an ffmpeg `-filter_complex` plan that the encoder applies (replacing `-c:a copy`). Preview is unchanged (export-only mixing).

**Tech Stack:** Flutter/Dart (Riverpod, flutter_test), ffmpeg/ffprobe, fvm.

**Reference spec:** `docs/superpowers/specs/2026-05-26-audio-mixing-design.md`

**Conventions:**
- Run tests with `fvm flutter test ...` from the relevant package dir.
- The recorder writes **mic = mono (1ch), system = stereo (2ch)** — role inference relies on this.
- Export input 0 = raw video frames on stdin; input 1 = the recording MP4 (`audioSourcePath`), which carries the audio streams (`1:a:0`, `1:a:1`).
- Never `git add -A` (untracked `DerivedData/`, `.claude/`, `.superpowers/`). Stage explicit paths. Never push.
- No macOS rebuild needed — this is pure Dart (engine + UI). Verify with `fvm flutter test`.

---

## File Structure

**New:**
- `packages/slipreel_engine/lib/state/audio_mix.dart` — `AudioMix` model.
- `packages/slipreel_engine/lib/export/audio_streams.dart` — `AudioStreamInfo`, `AudioRole`, `inferAudioRoles`.
- `packages/slipreel_engine/lib/export/audio_mix_args.dart` — `AudioMixPlan`, `buildAudioMixArgs`, `kMixedAudioBitrateKbps`.
- `packages/screen_recorder/lib/state/recording_audio_streams_provider.dart` — provider holding the opened recording's audio streams.
- Tests for each.

**Modified:**
- `packages/slipreel_engine/lib/state/editor_project_state.dart` — `audioMix` field + schema v4 migration.
- `packages/slipreel_engine/lib/state/editor_project_controller.dart` — gain/mute mutators.
- `packages/slipreel_engine/lib/export/ffmpeg_probe.dart` — all-audio-streams probe → `audioStreams`.
- `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart` — `audioMixPlan` field + `_argsFor` audio graph.
- `packages/slipreel_engine/lib/export/export_pipeline.dart` — build plan, pass to encoder.
- `packages/slipreel_engine/lib/export/export_estimator.dart` — doc note (audio re-encoded).
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart` — per-role volume section.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — probe audio streams on open → provider; export uses plan bitrate for the estimate.

---

## Task 1: `AudioMix` model

**Files:**
- Create: `packages/slipreel_engine/lib/state/audio_mix.dart`
- Test: `packages/slipreel_engine/test/state/audio_mix_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/state/audio_mix_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/audio_mix.dart';

void main() {
  test('defaults are unity, unmuted', () {
    const m = AudioMix();
    expect(m.micGainPercent, 100);
    expect(m.systemGainPercent, 100);
    expect(m.micMuted, isFalse);
    expect(m.systemMuted, isFalse);
  });

  test('round-trips through JSON', () {
    const m = AudioMix(
        micGainPercent: 80, micMuted: true,
        systemGainPercent: 150, systemMuted: false);
    expect(AudioMix.fromJson(m.toJson()), m);
  });

  test('fromJson fills defaults for missing keys', () {
    expect(AudioMix.fromJson(const {}), const AudioMix());
  });

  test('copyWith replaces only named fields', () {
    const m = AudioMix();
    final n = m.copyWith(systemGainPercent: 50, micMuted: true);
    expect(n.systemGainPercent, 50);
    expect(n.micMuted, isTrue);
    expect(n.micGainPercent, 100);
  });

  test('clamps gains to 0..200', () {
    expect(const AudioMix(micGainPercent: 999).micGainPercent, 200);
    expect(const AudioMix(systemGainPercent: -5).systemGainPercent, 0);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/state/audio_mix_test.dart
```
Expected: FAIL — `audio_mix.dart` does not exist.

- [ ] **Step 3: Create the model**

Create `packages/slipreel_engine/lib/state/audio_mix.dart`:
```dart
/// Per-track volume settings for the two possible recording audio tracks
/// (microphone, system). Gains are a percentage: 0 = silent, 100 = unchanged,
/// up to 200 = ~+6 dB boost. Stored by role; the physical track index is
/// resolved at export from a probe. Mute preserves the gain value.
class AudioMix {
  final int micGainPercent;
  final bool micMuted;
  final int systemGainPercent;
  final bool systemMuted;

  const AudioMix({
    int micGainPercent = 100,
    this.micMuted = false,
    int systemGainPercent = 100,
    this.systemMuted = false,
  })  : micGainPercent =
            micGainPercent < 0 ? 0 : (micGainPercent > 200 ? 200 : micGainPercent),
        systemGainPercent = systemGainPercent < 0
            ? 0
            : (systemGainPercent > 200 ? 200 : systemGainPercent);

  Map<String, dynamic> toJson() => {
        'micGainPercent': micGainPercent,
        'micMuted': micMuted,
        'systemGainPercent': systemGainPercent,
        'systemMuted': systemMuted,
      };

  factory AudioMix.fromJson(Map<String, dynamic> json) => AudioMix(
        micGainPercent: (json['micGainPercent'] as num?)?.round() ?? 100,
        micMuted: json['micMuted'] as bool? ?? false,
        systemGainPercent: (json['systemGainPercent'] as num?)?.round() ?? 100,
        systemMuted: json['systemMuted'] as bool? ?? false,
      );

  AudioMix copyWith({
    int? micGainPercent,
    bool? micMuted,
    int? systemGainPercent,
    bool? systemMuted,
  }) =>
      AudioMix(
        micGainPercent: micGainPercent ?? this.micGainPercent,
        micMuted: micMuted ?? this.micMuted,
        systemGainPercent: systemGainPercent ?? this.systemGainPercent,
        systemMuted: systemMuted ?? this.systemMuted,
      );

  @override
  bool operator ==(Object other) =>
      other is AudioMix &&
      other.micGainPercent == micGainPercent &&
      other.micMuted == micMuted &&
      other.systemGainPercent == systemGainPercent &&
      other.systemMuted == systemMuted;

  @override
  int get hashCode =>
      Object.hash(micGainPercent, micMuted, systemGainPercent, systemMuted);
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/state/audio_mix_test.dart
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/state/audio_mix.dart \
        packages/slipreel_engine/test/state/audio_mix_test.dart
git commit -m "feat(engine): AudioMix model"
```

---

## Task 2: `EditorProjectState.audioMix` + schema v4

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_state_test.dart` (create or append)

**Context:** `currentSchemaVersion` is `3`. The migration chain `_schemaMigrations` (index i = vi→vi+1) currently ends at the v2→v3 entry (index 2). Adding v4 requires bumping the version AND appending a v3→v4 entry (else `migrateEditorProjectJson` throws for v3 sidecars). `audioMix` is additive, so the migration is a pure version-bump; `fromJson` supplies the default when the key is absent.

- [ ] **Step 1: Write the failing test**

Create/append `packages/slipreel_engine/test/state/editor_project_state_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('audioMix round-trips through toJson/fromJson', () {
    final s = EditorProjectState.defaults().copyWith(
        audioMix: const AudioMix(systemGainPercent: 60, micMuted: true));
    final restored = EditorProjectState.fromJson(s.toJson());
    expect(restored.audioMix,
        const AudioMix(systemGainPercent: 60, micMuted: true));
  });

  test('defaults() has unity AudioMix', () {
    expect(EditorProjectState.defaults().audioMix, const AudioMix());
  });

  test('a v3 sidecar (no audioMix) migrates to v4 with unity defaults', () {
    final v3 = {
      'schemaVersion': 3,
      'timeline': {'zoomTracks': [{'regions': <dynamic>[]}]},
    };
    final migrated = migrateEditorProjectJson(v3);
    expect(migrated['schemaVersion'], 4);
    // fromJson supplies the default audioMix when the key is absent:
    final state = EditorProjectState.fromJson(v3);
    expect(state.audioMix, const AudioMix());
  });

  test('toJson advertises schemaVersion 4', () {
    expect(EditorProjectState.defaults().toJson()['schemaVersion'], 4);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/state/editor_project_state_test.dart
```
Expected: FAIL — `audioMix` not a member / schemaVersion is 3 / migration throws for v3.

- [ ] **Step 3: Add the field + migration**

In `packages/slipreel_engine/lib/state/editor_project_state.dart`:

(a) Add the import at the top:
```dart
import 'package:slipreel_engine/state/audio_mix.dart';
```
(b) Add the constructor param (after `this.fadeOut = Duration.zero,`):
```dart
    this.audioMix = const AudioMix(),
```
(c) Add the field (after the `fadeOut` field, ~line 129):
```dart
  /// Per-track recording-audio volume/mute, applied as an ffmpeg downmix at
  /// export. Preview is unaffected (export-only mixing).
  final AudioMix audioMix;
```
(d) Bump the version constant:
```dart
  static const int currentSchemaVersion = 4;
```
(e) Add to `copyWith` signature (after `Duration? fadeOut,`):
```dart
    AudioMix? audioMix,
```
and in its returned `EditorProjectState(...)` (after `fadeOut: fadeOut ?? this.fadeOut,`):
```dart
      audioMix: audioMix ?? this.audioMix,
```
(f) Add to `toJson()` (after the `'fadeOutMicros'` line):
```dart
    'audioMix': audioMix.toJson(),
```
(g) In `fromJson`, add to the returned `EditorProjectState(...)` (after the `fadeOut:` block):
```dart
      audioMix: json['audioMix'] is Map<String, dynamic>
          ? AudioMix.fromJson(json['audioMix'] as Map<String, dynamic>)
          : defaults.audioMix,
```
(h) Append the v3→v4 migration to `_schemaMigrations` (after the v2→v3 entry, before the closing `];`):
```dart
  // v3 → v4: add the per-track `audioMix` block. Additive — fromJson fills the
  // unity default when the key is absent, so the migration only bumps the
  // version marker so the chain reaches v4.
  (json) => {...json, 'schemaVersion': 4},
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/state/editor_project_state_test.dart
```
Expected: PASS. Then run the engine state suite to catch migration regressions:
```bash
fvm flutter test test/state/ 2>&1 | tail -5
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_project_state_test.dart
git commit -m "feat(engine): EditorProjectState.audioMix + schema v4 migration"
```

---

## Task 3: Controller gain/mute mutators

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  test('mutators update audioMix and clamp gains', () {
    final c = EditorProjectController();
    expect(c.current.audioMix, const AudioMix());

    c.setMicGain(50);
    expect(c.current.audioMix.micGainPercent, 50);

    c.setSystemGain(250); // clamps to 200
    expect(c.current.audioMix.systemGainPercent, 200);

    c.setMicMuted(true);
    expect(c.current.audioMix.micMuted, isTrue);

    c.setSystemMuted(true);
    expect(c.current.audioMix.systemMuted, isTrue);
    // unrelated fields preserved:
    expect(c.current.audioMix.micGainPercent, 50);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/state/editor_project_controller_audio_test.dart
```
Expected: FAIL — `setMicGain` etc. undefined.

- [ ] **Step 3: Add the mutators**

In `packages/slipreel_engine/lib/state/editor_project_controller.dart`:

(a) Add the import at the top:
```dart
import 'package:slipreel_engine/state/audio_mix.dart';
```
(b) Add these mutators (after `setFadeOut`, ~line 93):
```dart
  void setMicGain(int percent) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(micGainPercent: percent));

  void setMicMuted(bool value) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(micMuted: value));

  void setSystemGain(int percent) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(systemGainPercent: percent));

  void setSystemMuted(bool value) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(systemMuted: value));
```
(Clamping happens in the `AudioMix` constructor, so passing 250 stores 200.)

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/state/editor_project_controller_audio_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/state/editor_project_controller.dart \
        packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart
git commit -m "feat(engine): EditorProjectController audio gain/mute mutators"
```

---

## Task 4: `AudioStreamInfo` + `inferAudioRoles` + probe extension

**Files:**
- Create: `packages/slipreel_engine/lib/export/audio_streams.dart`
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_probe.dart`
- Test: `packages/slipreel_engine/test/export/audio_streams_test.dart` (create)

**Context:** `ffmpeg_probe.dart` currently has `_probeAudioBitrate` (selects `a:0`, parses one bitrate) and `FfmpegProbeResult.audioBitrateKbps`. We add `AudioStreamInfo` + a pure `parseAudioStreams(jsonString)` (testable without ffprobe) + `inferAudioRoles`, then wire the probe to populate a new `audioStreams` list (keeping `audioBitrateKbps` = first stream's, for the estimator).

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/export/audio_streams_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

void main() {
  group('parseAudioStreams', () {
    test('parses an ffprobe JSON stream list', () {
      const json = '''
      {"streams":[
        {"index":0,"codec_name":"aac","channels":1,"bit_rate":"128000"},
        {"index":1,"codec_name":"aac","channels":2,"bit_rate":"192000"}
      ]}''';
      final streams = parseAudioStreams(json);
      expect(streams.length, 2);
      expect(streams[0].index, 0);
      expect(streams[0].channels, 1);
      expect(streams[0].bitrateKbps, 128);
      expect(streams[1].channels, 2);
    });

    test('handles missing/absent bitrate and empty list', () {
      expect(parseAudioStreams('{"streams":[]}'), isEmpty);
      final s = parseAudioStreams(
          '{"streams":[{"index":0,"codec_name":"aac","channels":1}]}');
      expect(s.single.bitrateKbps, isNull);
    });
  });

  group('inferAudioRoles', () {
    AudioStreamInfo s(int i, int ch) =>
        AudioStreamInfo(index: i, channels: ch, codecName: 'aac');

    test('two tracks: mono=mic, stereo=system', () {
      final roles = inferAudioRoles([s(0, 1), s(1, 2)]);
      expect(roles[AudioRole.microphone], 0);
      expect(roles[AudioRole.system], 1);
    });

    test('one mono track = mic', () {
      final roles = inferAudioRoles([s(0, 1)]);
      expect(roles[AudioRole.microphone], 0);
      expect(roles.containsKey(AudioRole.system), isFalse);
    });

    test('one stereo track = system', () {
      final roles = inferAudioRoles([s(0, 2)]);
      expect(roles[AudioRole.system], 0);
      expect(roles.containsKey(AudioRole.microphone), isFalse);
    });

    test('two equal-channel tracks fall back to order (first=mic)', () {
      final roles = inferAudioRoles([s(0, 2), s(1, 2)]);
      expect(roles[AudioRole.microphone], 0);
      expect(roles[AudioRole.system], 1);
    });

    test('no tracks => empty', () {
      expect(inferAudioRoles(const []), isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/export/audio_streams_test.dart
```
Expected: FAIL — `audio_streams.dart` does not exist.

- [ ] **Step 3: Create `audio_streams.dart`**

Create `packages/slipreel_engine/lib/export/audio_streams.dart`:
```dart
import 'dart:convert';

/// Which recording track a probed audio stream represents.
enum AudioRole { microphone, system }

/// One audio stream from an `ffprobe` of the recording.
class AudioStreamInfo {
  final int index;
  final int channels;
  final String codecName;
  final int? bitrateKbps;

  const AudioStreamInfo({
    required this.index,
    required this.channels,
    required this.codecName,
    this.bitrateKbps,
  });

  @override
  bool operator ==(Object other) =>
      other is AudioStreamInfo &&
      other.index == index &&
      other.channels == channels &&
      other.codecName == codecName &&
      other.bitrateKbps == bitrateKbps;

  @override
  int get hashCode => Object.hash(index, channels, codecName, bitrateKbps);
}

/// Parses the JSON output of
/// `ffprobe -select_streams a -show_entries stream=index,codec_name,channels,bit_rate -of json`.
List<AudioStreamInfo> parseAudioStreams(String jsonString) {
  if (jsonString.trim().isEmpty) return const [];
  final decoded = jsonDecode(jsonString);
  final streams = (decoded is Map && decoded['streams'] is List)
      ? decoded['streams'] as List
      : const [];
  return streams.map((s) {
    final m = s as Map<String, dynamic>;
    final br = int.tryParse('${m['bit_rate'] ?? ''}');
    return AudioStreamInfo(
      index: (m['index'] as num?)?.toInt() ?? 0,
      channels: (m['channels'] as num?)?.toInt() ?? 0,
      codecName: m['codec_name'] as String? ?? '',
      bitrateKbps: (br == null || br <= 0) ? null : (br / 1000).round(),
    );
  }).toList();
}

/// Maps audio streams to recording roles using this app's convention
/// (mic = mono, system = stereo). Falls back to stream order when channel
/// counts don't disambiguate.
Map<AudioRole, int> inferAudioRoles(List<AudioStreamInfo> streams) {
  if (streams.isEmpty) return const {};
  if (streams.length == 1) {
    final s = streams.first;
    return {s.channels >= 2 ? AudioRole.system : AudioRole.microphone: s.index};
  }
  // Two (or more) streams: prefer a mono→mic / stereo→system split.
  final mono = streams.where((s) => s.channels <= 1).toList();
  final stereo = streams.where((s) => s.channels >= 2).toList();
  if (mono.isNotEmpty && stereo.isNotEmpty) {
    return {
      AudioRole.microphone: mono.first.index,
      AudioRole.system: stereo.first.index,
    };
  }
  // Ambiguous (same channel counts): fall back to order — first=mic, second=system.
  return {
    AudioRole.microphone: streams[0].index,
    AudioRole.system: streams[1].index,
  };
}
```

- [ ] **Step 4: Wire the probe**

In `packages/slipreel_engine/lib/export/ffmpeg_probe.dart`:

(a) Add the import at the top:
```dart
import 'audio_streams.dart';
```
(b) Add a field to `FfmpegProbeResult`: in the constructor (after `this.audioBitrateKbps,`):
```dart
    this.audioStreams = const [],
```
and as a field (after `audioBitrateKbps`):
```dart
  /// All audio streams in the source, in container order. Drives editor audio
  /// controls and the export mix. Empty when the source has no audio.
  final List<AudioStreamInfo> audioStreams;
```
(c) Replace `_probeAudioBitrate` with an all-streams probe, and update the call. Replace the call site (line ~134):
```dart
  final audioStreams = await _probeAudioStreams(path);
  final audioBitrateKbps =
      audioStreams.isEmpty ? null : audioStreams.first.bitrateKbps;
```
and the returned result (add the field):
```dart
  return FfmpegProbeResult(
    width: w,
    height: h,
    fps: fps,
    nbFrames: nbFrames,
    durationSec: dur,
    audioBitrateKbps: audioBitrateKbps,
    audioStreams: audioStreams,
  );
```
(d) Replace the `_probeAudioBitrate` function with:
```dart
Future<List<AudioStreamInfo>> _probeAudioStreams(String path) async {
  try {
    final result = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'a',
      '-show_entries', 'stream=index,codec_name,channels,bit_rate',
      '-of', 'json',
      path,
    ]);
    if (result.exitCode != 0) return const [];
    return parseAudioStreams(result.stdout as String);
  } catch (_) {
    return const [];
  }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/export/audio_streams_test.dart
fvm flutter test test/export/ 2>&1 | tail -5
```
Expected: PASS (the new tests + any existing export tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/export/audio_streams.dart \
        packages/slipreel_engine/lib/export/ffmpeg_probe.dart \
        packages/slipreel_engine/test/export/audio_streams_test.dart
git commit -m "feat(engine): probe all audio streams + role inference"
```

---

## Task 5: `buildAudioMixArgs` + `AudioMixPlan`

**Files:**
- Create: `packages/slipreel_engine/lib/export/audio_mix_args.dart`
- Test: `packages/slipreel_engine/test/export/audio_mix_args_test.dart` (create)

**Context:** The pure core. Turns probed streams + `AudioMix` into the ffmpeg audio filtergraph. Input 1 carries the recording's audio (`1:a:<index>`). A track is "usable" when its role is present, not muted, and gain > 0. Gain fraction = `percent/100` (e.g. `150 → 1.5`). Output is always normalized to stereo/48k via `aformat`.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/export/audio_mix_args_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/state/audio_mix.dart';

void main() {
  AudioStreamInfo s(int i, int ch) =>
      AudioStreamInfo(index: i, channels: ch, codecName: 'aac');

  test('no streams => no audio', () {
    final p = buildAudioMixArgs(const [], const AudioMix());
    expect(p.filterComplex, isNull);
    expect(p.mapLabel, isNull);
    expect(p.bitrateKbps, isNull);
  });

  test('single mic track at 100%', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix());
    expect(p.filterComplex,
        '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]');
    expect(p.mapLabel, '[aout]');
    expect(p.bitrateKbps, 192);
  });

  test('single track muted => no audio', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix(micMuted: true));
    expect(p.filterComplex, isNull);
    expect(p.mapLabel, isNull);
  });

  test('single track at 0% => no audio', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix(micGainPercent: 0));
    expect(p.filterComplex, isNull);
  });

  test('two tracks both 100% => amix normalize=0', () {
    final p = buildAudioMixArgs([s(0, 1), s(1, 2)], const AudioMix());
    expect(p.filterComplex,
        '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[a0];'
        '[1:a:1]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[a1];'
        '[a0][a1]amix=inputs=2:normalize=0[aout]');
    expect(p.mapLabel, '[aout]');
    expect(p.bitrateKbps, 192);
  });

  test('two tracks, system muted => single mic chain', () {
    final p = buildAudioMixArgs(
        [s(0, 1), s(1, 2)], const AudioMix(systemMuted: true));
    expect(p.filterComplex,
        '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]');
    expect(p.mapLabel, '[aout]');
  });

  test('both muted => no audio', () {
    final p = buildAudioMixArgs([s(0, 1), s(1, 2)],
        const AudioMix(micMuted: true, systemMuted: true));
    expect(p.filterComplex, isNull);
  });

  test('boost 200% => volume=2.0', () {
    final p = buildAudioMixArgs([s(0, 1)], const AudioMix(micGainPercent: 200));
    expect(p.filterComplex, contains('volume=2.0'));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/export/audio_mix_args_test.dart
```
Expected: FAIL — `audio_mix_args.dart` does not exist.

- [ ] **Step 3: Create the builder**

Create `packages/slipreel_engine/lib/export/audio_mix_args.dart`:
```dart
import 'audio_streams.dart';
import '../state/audio_mix.dart';

/// AAC bitrate of the mixed export audio track.
const int kMixedAudioBitrateKbps = 192;

/// The ffmpeg audio plan for an export: an audio filtergraph producing
/// `[aout]`, the map label, and the target bitrate. All null when the export
/// has no audio (no streams, or every usable track muted / at 0%).
class AudioMixPlan {
  final String? filterComplex;
  final String? mapLabel;
  final int? bitrateKbps;
  const AudioMixPlan({this.filterComplex, this.mapLabel, this.bitrateKbps});

  bool get hasAudio => filterComplex != null && mapLabel != null;
}

class _Usable {
  final int index;
  final double fraction;
  const _Usable(this.index, this.fraction);
}

/// ffmpeg volume fraction, e.g. 1.0 / 1.5 / 0.5.
String _fracStr(double f) => f.toString();

/// Builds the export audio plan from probed [streams] and the editor [mix].
/// Input 1 (the recording) carries the audio streams.
AudioMixPlan buildAudioMixArgs(List<AudioStreamInfo> streams, AudioMix mix) {
  final roles = inferAudioRoles(streams);

  final usable = <_Usable>[];
  // Microphone first so its chain is [a0] in the 2-track case.
  if (roles.containsKey(AudioRole.microphone) &&
      !mix.micMuted &&
      mix.micGainPercent > 0) {
    usable.add(_Usable(roles[AudioRole.microphone]!, mix.micGainPercent / 100));
  }
  if (roles.containsKey(AudioRole.system) &&
      !mix.systemMuted &&
      mix.systemGainPercent > 0) {
    usable.add(_Usable(roles[AudioRole.system]!, mix.systemGainPercent / 100));
  }

  if (usable.isEmpty) {
    return const AudioMixPlan();
  }
  if (usable.length == 1) {
    final u = usable.single;
    return AudioMixPlan(
      filterComplex: '[1:a:${u.index}]volume=${_fracStr(u.fraction)},'
          'aformat=sample_rates=48000:channel_layouts=stereo[aout]',
      mapLabel: '[aout]',
      bitrateKbps: kMixedAudioBitrateKbps,
    );
  }
  // Two usable tracks: per-track volume → amix(normalize=0).
  final chains = <String>[];
  for (var i = 0; i < usable.length; i++) {
    final u = usable[i];
    chains.add('[1:a:${u.index}]volume=${_fracStr(u.fraction)},'
        'aformat=sample_rates=48000:channel_layouts=stereo[a$i]');
  }
  final mixInputs = List.generate(usable.length, (i) => '[a$i]').join();
  chains.add('${mixInputs}amix=inputs=${usable.length}:normalize=0[aout]');
  return AudioMixPlan(
    filterComplex: chains.join(';'),
    mapLabel: '[aout]',
    bitrateKbps: kMixedAudioBitrateKbps,
  );
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/export/audio_mix_args_test.dart
```
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/export/audio_mix_args.dart \
        packages/slipreel_engine/test/export/audio_mix_args_test.dart
git commit -m "feat(engine): buildAudioMixArgs (amix filtergraph builder)"
```

---

## Task 6: Encoder applies the audio plan

**Files:**
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart`
- Test: `packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart` (create)

**Context:** Replace the `-map 1:a:0 -c:a copy` block. When the plan has audio, route BOTH video and audio through `-filter_complex` (a `[0:v]…[vout]` video chain + the plan's audio chains) to avoid `-vf`/`-filter_complex` coexistence issues; encode `-c:a aac`. When no audio, keep today's behavior (no audio input/map, `-vf` for scaling). Expose `_argsFor` for testing.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
import 'package:slipreel_engine/export/ffmpeg_encoder.dart';

void main() {
  test('no audio plan => no audio input/map/codec', () {
    final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000);
    final args = enc.argsForTesting('libx264');
    expect(args.contains('-c:a'), isFalse);
    expect(args.contains('-filter_complex'), isFalse);
  });

  test('audio plan => filter_complex + aac', () {
    final enc = FfmpegEncoder(
      outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
      bitrateKbps: 2000,
      audioSourcePath: '/tmp/in.mp4',
      audioMixPlan: const AudioMixPlan(
        filterComplex:
            '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]',
        mapLabel: '[aout]',
        bitrateKbps: 192,
      ),
    );
    final args = enc.argsForTesting('libx264');
    final joined = args.join(' ');
    expect(joined, contains('-i /tmp/in.mp4'));
    expect(joined, contains('-filter_complex'));
    expect(joined, contains('[aout]'));
    expect(joined, contains('-map [aout]'));
    expect(joined, contains('-c:a aac'));
    expect(joined, contains('-b:a 192k'));
    expect(args.contains('copy'), isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/export/ffmpeg_encoder_args_test.dart
```
Expected: FAIL — `audioMixPlan` / `argsForTesting` undefined.

- [ ] **Step 3: Update the encoder**

In `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart`:

(a) Add the import at the top:
```dart
import 'audio_mix_args.dart';
```
(b) Add the field (after `audioSourcePath`):
```dart
  /// When non-null and [AudioMixPlan.hasAudio], the export muxes audio from
  /// [audioSourcePath] through this ffmpeg filtergraph (per-track volume +
  /// amix downmix) instead of copying. Null/`!hasAudio` ⇒ video-only output.
  final AudioMixPlan? audioMixPlan;
```
(c) Add it to the constructor (after `this.audioSourcePath,`):
```dart
    this.audioMixPlan,
```
(d) Replace the whole `_argsFor` body with:
```dart
  List<String> _argsFor(String codec) {
    final plan = audioMixPlan;
    final hasAudio = audioSourcePath != null && (plan?.hasAudio ?? false);
    final needsScale = width != sourceWidth || height != sourceHeight;

    final args = <String>[
      '-loglevel', 'error',
      '-y',
      '-f', 'rawvideo',
      '-pix_fmt', pixelFormat.ffmpegName,
      '-s', '${sourceWidth}x$sourceHeight',
      '-r', '$sourceFps',
      '-i', '-',
    ];

    final scaleChain = 'scale=$width:$height:force_original_aspect_ratio=decrease,'
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1';

    if (hasAudio) {
      // Audio present: route video + audio through one -filter_complex so we
      // never mix -vf with -filter_complex (which can conflict).
      args.addAll(['-i', audioSourcePath!]);
      final videoChain =
          needsScale ? '[0:v]$scaleChain[vout]' : '[0:v]null[vout]';
      args.addAll(['-filter_complex', '$videoChain;${plan!.filterComplex!}']);
      args.addAll(['-map', '[vout]', '-map', plan.mapLabel!]);
      args.addAll(['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      args.addAll(['-r', '$fps']);
      args.addAll(['-c:a', 'aac', '-b:a', '${plan.bitrateKbps}k']);
    } else {
      // Video only (today's path): -vf for scaling, no audio.
      args.addAll(['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      if (needsScale) {
        args.addAll(['-vf', scaleChain]);
      }
      args.addAll(['-r', '$fps']);
    }
    args.add(outputPath);
    return args;
  }

  /// Test seam: the resolved ffmpeg arg list for [codec].
  List<String> argsForTesting(String codec) => _argsFor(codec);
```
(e) Update the `audioSourcePath` doc comment (line ~49) since it's no longer `-c:a copy`:
```dart
  /// Optional path to the source MP4 carrying the recording's audio. When an
  /// [audioMixPlan] with audio is supplied, its audio streams are mixed and
  /// re-encoded to AAC into the output; otherwise the output has no audio.
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test test/export/ffmpeg_encoder_args_test.dart
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/export/ffmpeg_encoder.dart \
        packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart
git commit -m "feat(engine): encoder applies audio mix plan (amix -> aac)"
```

---

## Task 7: Pipeline builds + passes the plan

**Files:**
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Modify: `packages/slipreel_engine/lib/export/export_estimator.dart` (doc only)

**Context:** The pipeline already has `projectState` and the probe result `probed` (with `audioStreams`). Build the `AudioMixPlan` and pass it to the encoder. No new unit test (the builder + encoder-args are already covered; integration is verified by the manual export in Task 10). Verify nothing breaks by running the engine suite.

- [ ] **Step 1: Build + pass the plan**

In `packages/slipreel_engine/lib/export/export_pipeline.dart`:

(a) Add imports at the top (match existing import style):
```dart
import 'audio_mix_args.dart';
```
(`projectState` and `probed` are already in scope in `run`.)

(b) Just before the `final encoder = FfmpegEncoder(` construction (line ~139), add:
```dart
    final audioMixPlan =
        buildAudioMixArgs(probed.audioStreams, projectState.audioMix);
```
(c) Add the field to the `FfmpegEncoder(...)` constructor call (after `audioSourcePath: sourcePath,`):
```dart
      audioMixPlan: audioMixPlan,
```

- [ ] **Step 2: Update the estimator doc**

In `packages/slipreel_engine/lib/export/export_estimator.dart`, update the `estimateOutputBytes` doc comment that says audio is muxed with `-c:a copy`:
```dart
  /// Estimated output bytes. For [ExportFormat.mp4] this is video bitrate ×
  /// duration plus, when the export will contain audio, the mixed AAC track's
  /// bytes (callers pass the mixed-track bitrate, e.g. kMixedAudioBitrateKbps,
  /// or null when the export has no audio). GIF applies a 0.6 factor and skips
  /// audio.
```
(The function body is unchanged — it already multiplies `audioBitrateKbps × duration`. The caller in Task 8 passes the plan's bitrate.)

- [ ] **Step 3: Verify the engine suite**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
fvm flutter test 2>&1 | tail -5
```
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/export/export_pipeline.dart \
        packages/slipreel_engine/lib/export/export_estimator.dart
git commit -m "feat(engine): export pipeline builds + applies the audio mix plan"
```

---

## Task 8: Provider + probe-on-open + export estimate

**Files:**
- Create: `packages/screen_recorder/lib/state/recording_audio_streams_provider.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/state/recording_audio_streams_provider_test.dart` (create)

**Context:** The audio tab (Task 9) needs to know which roles exist; the export estimate should reflect the mixed AAC bitrate. Add a simple `StateProvider<List<AudioStreamInfo>>` populated when the editor opens (the playback screen already probes via `ffmpegProbe`), and have the export estimate use the plan's bitrate.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/recording_audio_streams_provider_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

void main() {
  test('defaults to empty and accepts an update', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(recordingAudioStreamsProvider), isEmpty);
    c.read(recordingAudioStreamsProvider.notifier).state = [
      const AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
    ];
    expect(c.read(recordingAudioStreamsProvider).single.channels, 1);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/state/recording_audio_streams_provider_test.dart
```
Expected: FAIL — provider does not exist.

- [ ] **Step 3: Create the provider**

Create `packages/screen_recorder/lib/state/recording_audio_streams_provider.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

/// The opened recording's audio streams (probed when the editor loads).
/// Empty until populated / when the recording has no audio. Drives the
/// editor's per-track audio controls.
final recordingAudioStreamsProvider =
    StateProvider<List<AudioStreamInfo>>((ref) => const []);
```

- [ ] **Step 4: Populate on editor open + use plan bitrate for the estimate**

In `packages/screen_recorder/lib/ui/screens/playback_screen.dart`:

(a) Add imports (match existing style):
```dart
import '../../state/recording_audio_streams_provider.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
```
(b) In `_initializeVideo` (or wherever the screen first has the source path; near the existing init, ~line 170-240), after the video controller initializes, probe and publish the streams. Add:
```dart
    // Probe the recording's audio streams once so the audio tab knows which
    // per-track controls to show. Non-fatal: failure leaves it empty.
    final probedForAudio = await ffmpegProbe(path: widget.videoPath);
    if (mounted) {
      ref.read(recordingAudioStreamsProvider.notifier).state =
          probedForAudio.audioStreams;
    }
```
(If `ffmpegProbe` is already imported and called elsewhere in the screen, reuse its result instead of a second probe — set the provider from that existing `probed.audioStreams`.)
(c) In `_handleExport`, where the `ExportDialog` is built with `audioBitrateKbps: probed.audioBitrateKbps`, change it to the mixed-export bitrate derived from the plan:
```dart
      audioBitrateKbps: buildAudioMixArgs(
              probed.audioStreams,
              ref.read(editorProjectControllerProvider).audioMix)
          .bitrateKbps,
```
(This makes the size estimate reflect the re-encoded AAC track — or null/no audio when everything is muted. `editorProjectControllerProvider` is already used in this screen.)

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/state/recording_audio_streams_provider_test.dart
fvm flutter test 2>&1 | tail -5
```
Expected: provider test passes; full app suite still green (fix any compile fallout in playback_screen).

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/state/recording_audio_streams_provider.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/state/recording_audio_streams_provider_test.dart
git commit -m "feat(editor): probe audio streams on open + mixed-bitrate estimate"
```

---

## Task 9: Audio tab — per-track volume controls

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart`
- Test: `packages/screen_recorder/test/ui/inspector/audio_tab_mix_test.dart` (create)

**Context:** The `AudioTab` is a `StatefulWidget` (local `_selected` for background-music presets — keep it). Add a "Recording audio" section ABOVE the background section, implemented as a separate `ConsumerWidget` so the Riverpod reads stay isolated. It watches `recordingAudioStreamsProvider` (which roles exist) and `editorProjectControllerProvider` (current gains), and writes via the controller. Show a row per present role; if no audio streams, show an empty-state note.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/ui/inspector/audio_tab_mix_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/audio_tab.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

void main() {
  Widget host(List<AudioStreamInfo> streams) => ProviderScope(
        overrides: [
          recordingAudioStreamsProvider.overrideWith((ref) => streams),
        ],
        child: const MaterialApp(home: Scaffold(body: AudioTab())),
      );

  testWidgets('shows Microphone + System rows for a mic+system recording',
      (t) async {
    await t.pumpWidget(host(const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
      AudioStreamInfo(index: 1, channels: 2, codecName: 'aac'),
    ]));
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System audio'), findsOneWidget);
  });

  testWidgets('shows only Microphone for a mic-only recording', (t) async {
    await t.pumpWidget(host(const [
      AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
    ]));
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System audio'), findsNothing);
  });

  testWidgets('shows empty state when there is no recorded audio', (t) async {
    await t.pumpWidget(host(const []));
    expect(find.text('No audio in this recording'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/ui/inspector/audio_tab_mix_test.dart
```
Expected: FAIL — no "Recording audio" rows / `AudioTab` not Riverpod-aware.

- [ ] **Step 3: Add the recording-audio section**

In `packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart`:

(a) Add imports:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
```
(b) Insert the new section at the TOP of the existing `ListView` children (before the `'Background audio'` Text), so the build's `children: [` list starts with:
```dart
        const _RecordingAudioSection(),
        const InspectorSectionDivider(),
        const Text(
          'Background audio',
          ...
```
(c) Add the `_RecordingAudioSection` ConsumerWidget at the bottom of the file:
```dart
class _RecordingAudioSection extends ConsumerWidget {
  const _RecordingAudioSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streams = ref.watch(recordingAudioStreamsProvider);
    final roles = inferAudioRoles(streams);
    final mix = ref.watch(editorProjectControllerProvider).audioMix;
    final ctl = ref.read(editorProjectControllerProvider.notifier);

    final rows = <Widget>[];
    if (roles.containsKey(AudioRole.microphone)) {
      rows.add(_VolumeRow(
        label: 'Microphone',
        percent: mix.micGainPercent,
        muted: mix.micMuted,
        onChanged: ctl.setMicGain,
        onMuteToggle: () => ctl.setMicMuted(!mix.micMuted),
      ));
    }
    if (roles.containsKey(AudioRole.system)) {
      rows.add(_VolumeRow(
        label: 'System audio',
        percent: mix.systemGainPercent,
        muted: mix.systemMuted,
        onChanged: ctl.setSystemGain,
        onMuteToggle: () => ctl.setSystemMuted(!mix.systemMuted),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Recording audio',
            style: TextStyle(
                color: kInspectorMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Text('No audio in this recording',
              style: TextStyle(color: kInspectorMuted, fontSize: 13))
        else
          ...rows,
      ],
    );
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
    required this.label,
    required this.percent,
    required this.muted,
    required this.onChanged,
    required this.onMuteToggle,
  });

  final String label;
  final int percent;
  final bool muted;
  final ValueChanged<int> onChanged;
  final VoidCallback onMuteToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  muted ? Icons.volume_off : Icons.volume_up,
                  size: 18,
                  color: muted ? kInspectorMuted : Colors.white,
                ),
                onPressed: onMuteToggle,
              ),
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              Text('$percent%',
                  style: const TextStyle(color: kInspectorMuted, fontSize: 12)),
            ],
          ),
          Slider(
            value: percent.toDouble(),
            min: 0,
            max: 200,
            divisions: 40,
            onChanged: muted ? null : (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}
```
(`kInspectorMuted` etc. are already imported via `inspector_widgets.dart` at the top of the file. `AudioTab` itself stays a `StatefulWidget` — only the new section is a `ConsumerWidget`, which works fine nested inside.)

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/ui/inspector/audio_tab_mix_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart \
        packages/screen_recorder/test/ui/inspector/audio_tab_mix_test.dart
git commit -m "feat(editor): per-track volume controls in the audio tab"
```

---

## Task 10: Manual export verification

**Files:** none (verification only).

- [ ] **Step 1: Full suite green first**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && fvm flutter test 2>&1 | tail -3
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder && fvm flutter test 2>&1 | tail -3
```
Expected: all pass.

- [ ] **Step 2: Run the app and export a mic+system recording**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter run -d macos
```
Open a recording that has BOTH mic and system audio. In the inspector **Audio** tab, set Microphone to ~100% and System to ~50%. Export.

- [ ] **Step 3: Verify the output has one mixed stereo AAC track**

```bash
f=<the exported file path>
ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels -of default=noprint_wrappers=1 "$f"
```
Expected: exactly ONE `codec_type=audio` stream, `codec_name=aac`, `channels=2`, plus the video. Listen: both sources audible with system quieter.

- [ ] **Step 4: Mute + single-track + boost checks**

- Mute Microphone, export → only system audio is heard.
- Open a **mic-only** recording → only the Microphone row shows; export → one AAC track with the mic.
- Open a **system-only** recording → only System row; export works.
- Set a track to 200% → audibly louder (may clip — expected).
- A recording with **no audio** → audio tab shows "No audio in this recording"; export produces a video-only file (`ffprobe` shows no audio stream).

- [ ] **Step 5: Done — no commit (verification only).**

If any scenario misbehaves, treat as a bug: inspect the actual ffmpeg args (the encoder logs `encode (<codec>): ffmpeg …` via `AppLogger.ffmpeg`) and the `buildAudioMixArgs` output, and fix before declaring done.

---

## Final review checklist

- [ ] `slipreel_engine` + `screen_recorder` suites green.
- [ ] All Task 10 scenarios verified (2-track mix, mute, mic-only, system-only, boost, no-audio).
- [ ] Update the `audio_capture_subproject2.md` / roadmap memory: the interim "only mic track is heard" limitation is RESOLVED by S3.
- [ ] Confirm the preview-is-export-only limitation is acceptable as shipped (documented in the spec).
