# Editor Audio Mixing + Export Downmix (Sub-project 3) — Design

**Date:** 2026-05-26
**Status:** Approved design, ready for implementation plan.
**Context:** Final sub-project of the 3-part audio feature. Sub-projects 1
(microphone) and 2 (system audio) are merged to `main`; recordings now contain
up to two audio tracks (mic = audio track 0, system = audio track 1). This adds
per-track volume control in the editor and bakes the mix into the export via an
ffmpeg `amix` downmix. See `2026-05-25-audio-capture-roadmap.md`.

## Goal

Let the user balance microphone vs system audio per recording with volume
controls in the editor, and produce **one mixed AAC audio track** in the export.
This resolves the standing limitation: today a mic+system recording exports/plays
only the first (mic) track.

## Key decisions (locked during brainstorming)

1. **Export-only mixing.** The mix is applied at export via ffmpeg. The editor
   **preview is unchanged** — it keeps playing the raw recording's default track
   (mic) through `video_player`. Per-track gains and system audio are NOT heard
   in preview; only the export reflects them. (Real-time preview mixing was
   judged too complex for the value — explicitly out of scope.)
2. **Gain model: percentage 0–200% + mute**, per track. 0% = silent, 100% =
   unchanged, 200% ≈ +6 dB boost. Maps to ffmpeg `volume=<percent/100>`. A
   separate mute toggle preserves the slider value.
3. **Gains stored by role, not index.** `EditorProjectState` holds mic/system
   gain+mute; role→physical-index is resolved at export from a probe. (Index
   varies: a system-only recording has system at track 0.)
4. **Role inference by channel count.** This app's recorder always writes
   **mic = mono, system = stereo** (Sub-projects 1/2). So a probe's channel
   counts reliably map tracks to roles — no track metadata needed, works for all
   existing recordings.
5. **Controls live in the inspector audio tab** (currently a stub). Only sliders
   for roles present in the recording are shown.
6. **No new export-dialog controls** — gains come from the editor project state.

## Architecture / data flow

```
Editor audio tab (sliders + mute)
        │ reads/writes via EditorProjectController
EditorProjectState.audioMix  ──persisted (schema v4)──▶ <video>.editor.json
        │
audioStreamsProvider ◀── ffmpeg_probe (audio stream list) ── on editor open
        │ (which sliders to show)                         │
        ▼                                                 ▼
Export:  ExportPipeline ── probe streams + read audioMix ─▶ buildAudioMixArgs
                                                            │ {filterComplex, mapLabel, bitrate}
                                                            ▼
                              ffmpeg_encoder: -map 0:v -filter_complex … -map [aout] -c:a aac
```

## Components

### 1. `AudioMix` model (project state)

New immutable model (in `slipreel_engine`, near `editor_project_state.dart`):
```dart
class AudioMix {
  final int micGainPercent;     // 0..200, default 100
  final bool micMuted;          // default false
  final int systemGainPercent;  // 0..200, default 100
  final bool systemMuted;       // default false
  const AudioMix({this.micGainPercent = 100, this.micMuted = false,
                  this.systemGainPercent = 100, this.systemMuted = false});
  Map<String, dynamic> toJson();
  factory AudioMix.fromJson(Map<String, dynamic>);
  AudioMix copyWith({...});
  // value equality
}
```
Attached to `EditorProjectState` as `audioMix` (default `const AudioMix()`).
- **Schema bump v3 → v4:** add `audioMix` to `toJson`; `fromJson` defaults it when
  absent; add a v3→v4 entry to the migration chain that injects the unity default
  so old `.editor.json` sidecars load unchanged.
- `EditorProjectController` mutators: `setMicGain(int)`, `setMicMuted(bool)`,
  `setSystemGain(int)`, `setSystemMuted(bool)` (clamp gains to 0..200).

### 2. Track detection — extend `ffmpeg_probe.dart`

Replace the `a:0`-only bitrate probe with an all-audio-streams probe:
```
ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels,bit_rate -of json
```
- New `AudioStreamInfo { int index; int channels; String codecName; int? bitrateKbps; }`.
- `FfmpegProbeResult` gains `List<AudioStreamInfo> audioStreams`; keep
  `audioBitrateKbps` (first stream) for the existing estimator/dialog call.
- **Role inference** helper `inferAudioRoles(streams)`:
  - 2 streams: the mono one → `microphone`, the stereo one → `system`; if both
    have equal channel counts, fall back to order (first=mic, second=system).
  - 1 stream: mono → mic, stereo → system.
  - 0 streams: none.
  Returns a role→index map (and the inverse) for the UI and the export.

### 3. Export filter-graph builder (the testable core)

Pure function (in `slipreel_engine/lib/export/`):
```dart
class AudioMixPlan { final String? filterComplex; final String? mapLabel; final int? bitrateKbps; }
AudioMixPlan buildAudioMixArgs(List<AudioStreamInfo> streams, AudioMix mix);
```
Logic (input 1 carries the recording audio; input 0 is the raw video on stdin):
- Determine usable tracks: each present role whose gain > 0 and not muted.
- **0 usable** → `AudioMixPlan(filterComplex: null, mapLabel: null, bitrateKbps: null)`
  (export adds no audio map and no `-c:a`).
- **1 usable** (index i, fraction g) →
  `[1:a:i]volume=<g>,aformat=sample_rates=48000:channel_layouts=stereo[aout]`,
  `mapLabel='[aout]'`, `bitrateKbps=192`.
- **2 usable** (mic index m gain gm, system index s gain gs) →
  ```
  [1:a:m]volume=<gm>,aformat=sample_rates=48000:channel_layouts=stereo[a0];
  [1:a:s]volume=<gs>,aformat=sample_rates=48000:channel_layouts=stereo[a1];
  [a0][a1]amix=inputs=2:normalize=0[aout]
  ```
  `mapLabel='[aout]'`, `bitrateKbps=192`.
- Gain fraction = `percent / 100` (e.g. 150 → `volume=1.5`). `normalize=0` keeps
  user-set levels (amix default would halve them). `aformat` normalizes mono+
  stereo to a clean stereo bed and avoids layout-mismatch errors.

### 4. Encoder — `ffmpeg_encoder.dart`

In `_argsFor`, replace the `-map 0:v -map 1:a:0` + `-c:a copy` block. Video map
`-map 0:v` stays. Given an `AudioMixPlan` with audio:
`-filter_complex "<filterComplex>" -map "<mapLabel>" -c:a aac -b:a <bitrate>k`.
With no audio: emit neither the filter nor `-c:a`. The encoder receives the plan
(and the audio input path) from the pipeline.

### 5. Pipeline — `export_pipeline.dart`

Before encoding: probe the source's audio streams, read `EditorProjectState.audioMix`,
call `buildAudioMixArgs`, and pass the resulting plan to the encoder along with the
existing `audioSourcePath` (= the recording). (If the screen already probed for the
export dialog, reuse that result to avoid a second ffprobe.)

### 6. Estimator — `export_estimator.dart`

Audio is now re-encoded, not copied. Use the plan's `bitrateKbps` (192, or null →
0 audio bytes) × duration for the audio-bytes term instead of the source bitrate.

### 7. Editor UI — `audio_tab.dart`

Extend the (stub) inspector audio tab with a "Recording audio" section:
- A **Microphone** row (0–200% slider, default 100%, + mute toggle) and a
  **System audio** row, each shown only when that role is present in the probe.
- 0 audio tracks → a quiet "No audio in this recording" empty state.
- Rows read `EditorProjectState.audioMix` and write via the controller mutators.

**Probe→UI wiring:** probe the recording's audio streams once when the editor
opens (in `playback_screen.dart`, alongside video init) and expose the
`List<AudioStreamInfo>` via a Riverpod provider (`recordingAudioStreamsProvider`).
The audio tab watches it; the export reads the same result.

## Error handling

- **0 audio tracks:** no audio controls, no audio in export (video-only) — handled
  by the plan's null branch.
- **All tracks muted / 0%:** same as 0 usable → no audio in export.
- **Probe failure / ffprobe missing:** treat as 0 audio streams (no controls,
  export video-only) and log; never block the editor or export.
- **Clipping:** `normalize=0` + boosting can clip; that is the user's choice (the
  gain sliders are theirs). No limiter in v1.

## Testing

- **Dart unit (priority):**
  - `buildAudioMixArgs`: 0 tracks → no audio; 1 track at 100/50/0%/muted; 2 tracks
    both 100% (amix, `normalize=0`); one muted → single `volume` map; both muted →
    no audio; boost 200% → `volume=2.0`; correct `-map`/label per case.
  - `inferAudioRoles`: mono→mic, stereo→system; 1-track and 2-track cases;
    equal-channel fallback to order; 0 tracks.
  - `ffmpeg_probe` parsing of the JSON stream list into `AudioStreamInfo`.
  - `AudioMix` JSON round-trip; `EditorProjectState` **v3→v4 migration** (old
    sidecar without `audioMix` loads with unity defaults).
  - `EditorProjectController` mutators (clamping 0..200).
  - `export_estimator` with AAC bitrate and the 0-track case.
  - Audio-tab widget renders the correct rows for detected roles and updates state.
- **Manual:** export a mic+system clip at various gains/mutes → output has one
  **stereo AAC** track, balance audible; mute one → only the other; mic-only,
  system-only, and no-audio recordings all export correctly.

## Scope boundaries (NOT in Sub-project 3)

- **Preview does not reflect the mix** (export-only) — accepted limitation.
- No background-music / audio presets (the audio tab stub's original idea —
  separate feature).
- No limiter / clipping protection.
- No keyframed or fade volume automation (constant per-track gain only;
  `fadeIn`/`fadeOut` in state are unrelated and remain pending).
- No waveform display.

## Files

**New:**
- `packages/slipreel_engine/lib/...audio_mix.dart` (`AudioMix` model; co-locate with `EditorProjectState`)
- `packages/slipreel_engine/lib/export/audio_mix_args.dart` (`AudioMixPlan` + `buildAudioMixArgs`)
- `packages/slipreel_engine/lib/export/...audio_stream_info.dart` (`AudioStreamInfo` + `inferAudioRoles`) — or co-locate in `ffmpeg_probe.dart`
- `recordingAudioStreamsProvider` (app, near the editor providers)
- Tests for each of the above.

**Modified:**
- `editor_project_state.dart` — `audioMix` field + schema v4 migration.
- `editor_project_controller.dart` — gain/mute mutators.
- `ffmpeg_probe.dart` — all-streams probe + `AudioStreamInfo`/`inferAudioRoles`.
- `ffmpeg_encoder.dart` — `-filter_complex`/`amix` audio in `_argsFor`.
- `export_pipeline.dart` — probe + build plan + pass to encoder.
- `export_estimator.dart` — AAC re-encode bitrate / 0-track.
- `audio_tab.dart` — per-track volume sliders + mute.
- `playback_screen.dart` — probe audio streams on open → provider; export wiring.
