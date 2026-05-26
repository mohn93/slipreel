# Audio Capture — Roadmap (Sub-projects 2 & 3)

**Date:** 2026-05-25
**Purpose:** Capture the deferred scope so it can be picked up later as its own
brainstorm → spec → plan → implement cycles. Sub-project 1 (foundation +
microphone) is specced in `2026-05-25-audio-capture-microphone-design.md`.

The full feature was scoped during brainstorming as: a **microphone** dropdown
(device list + "Reduce noise and normalize volume" + "Disable auto gain
control" + "Don't record microphone") and a **system-audio** dropdown ("Record
system audio from all apps" / "from selected apps" / "Don't record system
audio"). Confirmed decisions that bind all three sub-projects:

- **Two separate audio tracks** in the MP4 (mic = track 0, system = track 1) —
  not a single mixed track. Sub-project 1 builds the track-keyed writer for this.
- **Full editor mixing** is in scope (Sub-project 3): per-track volume in the
  editor and a downmix on export.
- Native dropdowns are **native `NSMenu`s** (Flutter overlays clip in the tiny
  floating bar window) — reuse the gear-menu / `showMicrophoneMenu` pattern.
- macOS deployment target is **12.3**.

Dependency order: **1 → 2 → 3** (2 needs 1's track-keyed writer; 3 needs tracks
from 1 & 2).

---

## Sub-project 2 — System audio

**Goal:** Record system (app) audio as its own MP4 track; the bar's "No system
audio" control goes live with all-apps / selected-apps / off.

### Capture (native)
- **All apps:** set `SCStreamConfiguration.capturesAudio = true` (macOS 13+) on
  the existing screen-capture `SCStream` (`ScreenCaptureManager.swift`). Audio
  arrives on the stream's `SCStreamOutput` with type `.audio` as `CMSampleBuffer`s.
  Add an audio `SCStreamOutput` (separate from the video output handler) and
  route buffers to `LiveRecordingWriter.appendAudio(buf, role: .system)`.
- **Selected apps:** build the `SCContentFilter` from chosen `SCRunningApplication`s
  (`SCContentFilter(display:including applications:exceptingWindows:)`), still
  with `capturesAudio = true`. Only those apps' audio is captured. This changes
  the content filter used for the stream, so coordinate with how the source
  picker currently builds its filter.
- **Off:** `capturesAudio = false`; no `.system` track created.
- **macOS floor:** `capturesAudio` is macOS 13.0+. On 12.x, hide/disable system
  audio (the app's min target is 12.3) — gate with `#available(macOS 13.0, *)`.
  Consider whether to raise the floor to 13 instead.

### Track plumbing
- `LiveRecordingWriter.start(audioTracks:)` gains `.system`. System audio is
  typically **stereo, 48 kHz** — give the system input its own AAC settings
  (stereo) vs. the mic input (mono). Confirm channel count from the incoming
  `CMSampleBuffer` format.
- `RecordingSettings` gains `systemAudio: SystemAudioConfig?`
  (`{ mode: allApps | selectedApps, bundleIds: List<String> }`; null = off).
  Channel args gain `systemAudio`.

### UI / state
- New `SystemAudioController` (Riverpod) mirroring `MicrophoneController`.
- New native `showSystemAudioMenu(current) -> result` (NSMenu):
  ```
  ✓ Record system audio from all apps
    Record system audio from selected apps ▸ [app picker]
    ──────────
    Don't record system audio
  ```
- **App picker** for "selected apps": enumerate running apps with audio-capable
  windows (via `SCShareableContent.applications` / `runningApplications`), show
  a multi-select (likely a second NSMenu submenu or a small native panel modeled
  on `SourcePickerOverlay`). Persisting selected bundle IDs is optional.
- Bar's `_AvPlaceholder(volumeOff, 'No system audio')` → live control: speaker
  icon + label ("System audio" / "Selected apps" / "No system audio") + chevron,
  same truncation rule as the mic control.

### Permission
- System-audio capture rides on the existing **screen-recording** permission
  (no separate TCC prompt). If screen recording isn't granted, system audio
  can't be captured — surface the same way screen capture already does.

### Testing
- Dart: `SystemAudioConfig` JSON; `RecordingSettings` encoding; controller
  transitions; `RecordingController` wiring.
- Channel: `showSystemAudioMenu` encode/decode; app enumeration.
- Manual: record with all-apps → ffprobe shows a 2nd (stereo) audio track with
  app audio; selected-apps captures only chosen apps; off → only the mic track
  (or none).

---

## Sub-project 3 — Editor mixing + export downmix

**Goal:** Balance mic vs system volume in the editor and bake it into exports.

### Editor
- Editor reads the recording's audio tracks (probe via `ffmpeg_probe.dart` —
  currently probes only the first audio stream's bitrate; extend to detect track
  count / roles).
- Add per-track **volume controls** (mic / system) to the editor UI + project
  state (`editor_project_state.dart`, `timeline.dart`). Store gain per track in
  the project model. Decide where the controls live (an audio panel vs. timeline
  track headers).

### Export downmix
- Replace today's single-stream copy in `ffmpeg_encoder.dart`
  (`-map 0:v -map 1:a:0 -c:a copy`) with an **`amix`** filter graph that applies
  per-track gain and downmixes the two source tracks to one output track, e.g.:
  ```
  -filter_complex "[1:a:0]volume=<micGain>[a0];
                   [1:a:1]volume=<sysGain>[a1];
                   [a0][a1]amix=inputs=2:normalize=0[aout]"
  -map 0:v -map "[aout]" -c:a aac
  ```
  (Re-encode to AAC since we're filtering — no longer `-c:a copy`.)
- Handle the **1-track** case (mic-only or system-only recording): fall back to
  a single `volume` filter or straight copy.
- Update `export_estimator.dart` (audio is now re-encoded, not copied) and
  `export_pipeline.dart` (`audioSourcePath` already threaded through).

### Testing
- Dart: filter-graph builder produces correct `-filter_complex` for 0/1/2-track
  inputs and gain values; estimator accounts for AAC re-encode.
- Manual: export an edited clip with mic+system → output has one mixed track;
  changing the sliders changes the balance; mic-only and system-only exports
  still produce audio.

---

## Cross-cutting notes
- Keep the `writerActive` (first-video-PTS) guard when adding the system input —
  audio before the session start is dropped by design.
- `DerivedData/` under `screen_recorder_macos/example/macos/` is currently **not
  gitignored** and produces large status churn; consider adding it to
  `.gitignore` while in this area (unrelated cleanup — optional).
