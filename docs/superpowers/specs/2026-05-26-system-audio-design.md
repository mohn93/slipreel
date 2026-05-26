# System Audio Capture (Sub-project 2) — Design

**Date:** 2026-05-26
**Status:** Approved design, ready for implementation plan.
**Context:** Sub-project 2 of the 3-part audio feature. Sub-project 1 (microphone
capture + live level meter) is merged. This adds **system/app audio as a second
MP4 audio track**. Sub-project 3 (editor mixing + export downmix) remains
deferred. See `2026-05-25-audio-capture-roadmap.md`.

## Goal

When recording, optionally capture **system audio** — from **all apps** or from
a **user-selected set of apps** — as its own AAC track (track 1) alongside the
microphone track (track 0). The bar's disabled "No system audio" placeholder
becomes a live control. Two separate audio tracks is the agreed model; mixing is
Sub-project 3.

## Key decisions (locked during brainstorming)

1. **Both modes ship now:** all-apps, selected-apps (with a native multi-select
   app picker), and off.
2. **Dedicated audio-only `SCStream`.** System audio runs on its own `SCStream`,
   separate from the video stream. ScreenCaptureKit ties `capturesAudio` to the
   video content filter; a dedicated audio stream is the only way to decouple
   audio app-scope from the video source (so "all apps" / "selected apps" work
   regardless of whether you're recording a display, a window, or a region).
   The existing video stream is left untouched.
3. **Minimum macOS target raised to 13.0** (`capturesAudio` /
   `excludesCurrentProcessAudio` / audio `SCStream` config are 13.0+). No
   availability gates. Was 12.3.
4. **Native multi-select panel** for selected-apps, modeled on the existing
   `SourcePickerOverlay`.
5. **Excludes our own audio:** `excludesCurrentProcessAudio = true`.
6. **In-memory selection state**, mirroring `MicrophoneController` — resets to
   off each launch, no persistence.

## Architecture

```
RecordingBar (_SystemAudioControl)  ──tap──▶ _onSystemAudioTap
        │ watches                                    │
SystemAudioController (StateNotifier<SystemAudioConfig?>)   │ showSystemAudioMenu(current)
        │                                            ▼
        │                            native NSMenu  ──"selected apps…"──▶ native multi-select panel
        │                                            │ returns { cancelled, config }
        ▼                                            ▼
RecordingSettings.systemAudio ──toJson()──▶ startLiveRecording channel args
                                                     │
                              ScreenRecorderMacosPlugin.startLiveRecording
                                                     │ (systemAudio on?)
                                                     ▼
                              SystemAudioCaptureManager.start(mode:bundleIds:)
                                 dedicated audio SCStream → .audio CMSampleBuffers
                                                     │ onSampleBufferReceived
                                                     ▼
                              LiveRecordingWriter.appendAudio(sb, role: .system)
                                 → MP4 track 1 (stereo/48k AAC); mic = track 0
```

## Components

### 1. Native capture — `SystemAudioCaptureManager.swift` (new)

Mirrors `AudioCaptureManager`, but sources from a dedicated audio `SCStream`
rather than an `AVAudioEngine` tap. ScreenCaptureKit delivers `CMSampleBuffer`s
directly, so **no PCM conversion** is needed (unlike the mic path).

- `start(mode: SystemAudioMode, bundleIds: [String]) throws`
  - `SCStreamConfiguration`:
    - `capturesAudio = true`
    - `excludesCurrentProcessAudio = true`
    - `sampleRate = 48000`, `channelCount = 2`
    - minimal dummy video dimensions; **no `.screen` output is added**, so video
      frames are produced but never consumed.
  - `SCContentFilter`, built from a fresh `SCShareableContent` fetch:
    - **allApps** → `SCContentFilter(display: <main display>, excludingApplications: [], exceptingWindows: [])`
      (our own audio already excluded by the config flag).
    - **selectedApps** → `SCContentFilter(display: <main display>, including: <SCRunningApplications whose bundleIdentifier ∈ bundleIds>, exceptingWindows: [])`.
      If no running app matches, the manager does not start (see Error handling).
  - Adds an `SCStreamOutput` for `type: .audio`; each buffer is forwarded via
    `onSampleBufferReceived: ((CMSampleBuffer) -> Void)?` (same callback shape as
    the mic manager).
  - `try await stream.startCapture()`.
- `stop()` — `stopCapture` + teardown.
- `var onSampleBufferReceived: ((CMSampleBuffer) -> Void)?`

`SystemAudioMode` is a native enum `{ allApps, selectedApps }` decoded from the
channel args.

### 2. Wiring into the live recording path — `ScreenRecorderMacosPlugin.swift`

In `startLiveRecording` (the path the app actually uses):
- Decode `systemAudio` args (`["mode": "allApps"|"selectedApps", "bundleIds": [String]]`,
  absent/null = off) alongside the existing `microphone` args.
- Compute the writer's `audioTracks` from the enabled roles:
  - mic only → `[.microphone]`
  - system only → `[.system]`
  - both → `[.microphone, .system]`
  - neither → `[]`
- When system audio is on: create `SystemAudioCaptureManager`, set
  `onSampleBufferReceived = { [weak writer] sb in writer?.appendAudio(sb, role: .system) }`,
  then `start(mode:bundleIds:)`. The existing `writerActive` / first-video-PTS
  guard drops any audio before the session start — same as the mic.
- `stopLiveRecording` also stops the system-audio manager.

**No `LiveRecordingWriter` changes.** `AudioTrackRole.system`, stereo/48k AAC
settings (`audioSettings(for: .system)` already returns 2 channels), per-role
inputs, and the `appendAudio(_, role:)` guard already exist.

### 3. Dart model — `SystemAudioConfig`

```dart
enum SystemAudioMode { allApps, selectedApps }

class SystemAudioConfig {
  final SystemAudioMode mode;
  final List<String> bundleIds; // empty for allApps; chosen apps for selectedApps
  const SystemAudioConfig({required this.mode, this.bundleIds = const []});

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'bundleIds': bundleIds,
  };
  factory SystemAudioConfig.fromJson(Map<String, dynamic> j) => SystemAudioConfig(
    mode: SystemAudioMode.values.byName(j['mode'] as String),
    bundleIds: (j['bundleIds'] as List?)?.cast<String>() ?? const [],
  );
  SystemAudioConfig copyWith({SystemAudioMode? mode, List<String>? bundleIds});
  // value equality on mode + bundleIds (order-insensitive for bundleIds)
}
```
`null` = off.

### 4. State — `SystemAudioController`

A near-copy of `MicrophoneController`:
```dart
class SystemAudioController extends StateNotifier<SystemAudioConfig?> {
  SystemAudioController() : super(null);
  void set(SystemAudioConfig? config) { if (config != state) state = config; }
}
final systemAudioControllerProvider =
    StateNotifierProvider<SystemAudioController, SystemAudioConfig?>(...);
```
In-memory; resets to off each launch.

### 5. `RecordingSettings.systemAudio`

Add `final SystemAudioConfig? systemAudio;` to `RecordingSettings`; include
`'systemAudio': systemAudio?.toJson()` in `toJson()`; thread it through
`copyWith`. The method-channel `startLiveRecording` already forwards
`settings.toJson()`, so the Swift side receives it under `args["systemAudio"]`.

### 6. Native menu + app picker

**`showSystemAudioMenu(current) -> result`** — one native call returning a
complete config, like `showMicrophoneMenu`. NSMenu:
```
✓ Record system audio from all apps
  Record system audio from selected apps…     ← opens the picker panel
  ──────────
  Don't record system audio
```
The checkmark reflects `current`. When "selected apps…" is chosen, the native
side immediately presents the **multi-select panel**:
- Running audio-capable apps enumerated via `SCShareableContent.applications`
  (app name + icon + bundle id), already-selected ones pre-checked.
- **Done** (disabled when nothing is checked) returns the chosen bundleIds as a
  `selectedApps` config; **Cancel** aborts the whole interaction (no change).

**Result shape** mirrors mic: `{ "cancelled": Bool, "config": <SystemAudioConfig
json> | null }`. Platform-interface method `showSystemAudioMenu(SystemAudioConfig?
current) -> SystemAudioMenuResult { cancelled, config }`.

### 7. Bar control — `_SystemAudioControl`

Replace the disabled `_AvPlaceholder(LucideIcons.volumeOff, 'No system audio')`
with a real control mirroring `_MicControl`:
- Speaker icon: `volume2` (on) / `volumeOff` (off).
- Label: `"System audio"` (all apps) / the single app name or `"N apps"`
  (selected) / `"No system audio"` (off). Same fixed-width chip, left-anchored
  icon, ellipsized label, chevron, and hover-brighten as the mic control.
- Tap → `_onSystemAudioTap` (in `RecordingBarScreen`): read
  `systemAudioControllerProvider`, call `showSystemAudioMenu(current)`, and on a
  non-cancelled result `controller.set(result.config)`.
- **No live meter** (mic-specific; out of scope).

## Error handling (degrade gracefully — never abort a recording)

- **Permission:** system audio rides on the existing screen-recording TCC grant;
  no new prompt. If the dedicated audio stream fails to start (permission,
  transient SCK error), **log and drop the system track** — video + mic recording
  continues. System audio never fails the whole recording.
- **No apps resolved:** if `selectedApps` matches zero running apps at record
  time, skip system capture (no `.system` track). The picker's Done is disabled
  when nothing is checked.
- **Selected app quits mid-recording:** SCK handles it; that app's audio stops,
  no crash.
- `excludesCurrentProcessAudio = true` avoids capturing Slipreel's own sounds.

## Testing

- **Dart unit:**
  - `SystemAudioConfig` JSON round-trip: allApps, selectedApps with bundleIds,
    and off (null).
  - `SystemAudioController` transitions (off → all → selected → off).
  - `RecordingSettings.toJson()` includes `systemAudio` (and omits/null when off).
  - `_SystemAudioControl` renders the correct icon + label per state.
  - `_onSystemAudioTap` wiring: a non-cancelled `SystemAudioMenuResult` calls
    `controller.set`; a cancelled result leaves state unchanged.
  - `SystemAudioMenuResult` decode from the channel map.
- **Manual (ffprobe):**
  - all-apps → MP4 has a 2nd **stereo** audio track carrying app audio.
  - selected-apps → only the chosen apps' audio is present.
  - mic + system → two audio tracks, both starting at PTS 0 (reuses the
    already-verified writer; no drift).
  - off → only the mic track (or no audio track if mic is also off).
- Native `SCStream` audio is not unit-testable; covered by the manual pass.

## Scope boundaries (NOT in Sub-project 2)

- **No editor mixing / export downmix** — that's Sub-project 3.
- **Known interim limitation:** the export pipeline currently maps a single audio
  track (`-map 1:a:0 -c:a copy`), and playback plays the first/default track.
  So a **mic+system** recording contains both tracks in the raw MP4, but **only
  the mic track is heard in playback/export until Sub-project 3 mixing lands**. A
  **system-only** recording exports fine (it is the sole/first audio track). This
  is by design given the 1→2→3 dependency order, and is called out here so it is
  not a surprise.
- No live system-audio meter.
- No persistence of the selection (in-memory only).

## Files

**New:**
- `packages/screen_recorder_macos/macos/Classes/SystemAudioCaptureManager.swift`
- `packages/screen_recorder/lib/state/system_audio_controller.dart`
- `packages/screen_recorder/lib/...system_audio_config.dart` (model; co-locate
  with `MicrophoneConfig`'s file/dir)
- `packages/screen_recorder/lib/ui/bar/` — `_SystemAudioControl` (in
  `recording_bar.dart`, alongside `_MicControl`)
- Native multi-select panel (new Swift view modeled on `SourcePickerOverlay`).
- Tests: `system_audio_config_test.dart`, `system_audio_controller_test.dart`,
  bar control + wiring tests, `RecordingSettings` encoding test.

**Modified:**
- `ScreenRecorderMacosPlugin.swift` — `startLiveRecording`/`stopLiveRecording`
  wiring; new `showSystemAudioMenu` handler + panel presentation.
- `recording_settings.dart` — `systemAudio` field.
- Platform interface + method channel — `showSystemAudioMenu` +
  `SystemAudioMenuResult`.
- `recording_bar.dart` / `recording_bar_screen.dart` — control + `_onSystemAudioTap`.
- macOS project: raise deployment target 12.3 → 13.0 (Runner + plugin Podspec/
  xcconfig).
