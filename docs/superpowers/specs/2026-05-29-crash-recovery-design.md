# Crash recovery (sub-project C)

**Date:** 2026-05-29
**Status:** Approved (design)
**Scope:** Make mid-recording crashes recoverable. On next launch, detect any session that started but never cleanly stopped, list it in a modal, and offer per-row Recover (re-mux into a clean MP4 + restore cursor data) or Discard.

Sub-project C of the five-part 2026-05-28 backlog; B (first-run & permissions) and A (recording UX bundle) have shipped; D (click auto-zoom) and E (distribution) follow.

## Background

Today (`packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift:106-137`), `AVAssetWriter` is constructed with default settings — no `movieFragmentInterval`. The MP4 file written during recording has no playable `moov` atom until `finishWriting()` is called; a process kill mid-recording leaves an unplayable raw file.

Cursor data (`packages/slipreel_engine/lib/models/cursor_recording.dart:104-112`) is accumulated in memory throughout the session and dumped to `<videoPath>.cursor.json` only at stop time. A crash means the entire cursor track for that session is lost.

There is no "currently recording" persistent marker anywhere in the codebase — no `.lock`, no SharedPreferences flag, no sentinel file.

## Decisions (from brainstorming)

- **Recovery UX shape:** Modal on cold launch listing each candidate with per-row [Recover] / [Discard]. Recovered files land in Recents.
- **What to recover:** Video + audio + cursor positions (with a ≤ 5 s loss window).
- **Multiple partials:** Show as a list (up to 5 visible; `+N older` indicator beyond that). Per-row decisions.
- **Checkpoint cadence:** 5 seconds. AVAssetWriter `movieFragmentInterval = 5 s` for video/audio; cursor NDJSON flushed every 5 s.

## System overview

```
   recording start          recording stop (clean)
        │                          │
        ▼                          ▼
   SessionMarker.add ───┐    SessionMarker.remove
                        │            │
                        ▼            ▼
   ┌──────────────────────────────────────────────┐
   │  ~/Library/.../current_sessions.json         │
   │  [ { id, videoPath, cursorPath, startedAt }, … ] │
   └──────────────────────────────────────────────┘
        │                          │
        │      ┌───────────────────┘
        │      │
        │      ▼
   AVAssetWriter            CursorCheckpointer
   movieFragmentInterval=5s     batches positions
   → moof/mdat every 5 s        → flushes NDJSON every 5 s
        │                          │
        ▼                          ▼
   .mp4 (incrementally       .cursor.ndjson
    self-healing fMP4)        (append-only)

       ┌───────  on next cold launch  ───────┐
       │                                     │
       ▼                                     ▼
   RecoveryService                      RecoveryModal
   scans markers,                       lists candidates,
   filters to those whose               per-row Recover/Discard,
   video file exists & is non-empty.    runs ffmpeg re-mux on Recover,
                                        adds to RecordingHistoryStore.
```

## Components

### 1. Native: fragmented MP4
`packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`

One line, in `start()` immediately after the `AVAssetWriter` is constructed:

```swift
assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(5.0, preferredTimescale: 600)
```

The writer emits an upfront `moov` containing codec/dimension metadata, then a `moof` + `mdat` pair every 5 s of media time. On `finishWriting()`, a final fragment for remaining samples is written. On process kill mid-recording, the file has header `moov` + N complete fragments + (possibly) a partial fragment; AVFoundation-based players (and ffmpeg with our re-mux) read through the last complete fragment.

**Interaction with sub-project A's PTS rebase:** the `pausedOffset` math happens *before* `input.append`, so the writer sees the rebased timeline. Moof boxes reflect the rebased timeline → paused intervals stay excluded from the recovered output.

**Interaction with pause/resume:** AVAssetWriter keys fragments off the writer's clock, not the source clock. Pause/resume across a fragment boundary is handled internally; no special code needed.

### 2. `SessionMarker` + `SessionMarkerStore`
`packages/screen_recorder/lib/state/session_marker.dart` (new)

JSON file at `getApplicationSupportDirectory()/current_sessions.json`:

```json
{
  "version": 1,
  "sessions": [
    {
      "id": "1717000000",
      "videoPath": "/Users/.../Documents/recording_1717000000.mp4",
      "cursorNdjsonPath": "/Users/.../Documents/recording_1717000000.cursor.ndjson",
      "startedAt": "2026-05-29T15:30:00Z",
      "width": 2880,
      "height": 1800,
      "fps": 60
    }
  ]
}
```

`width / height / fps` are denormalised so the recovery modal can render meaningful labels without opening the video.

```dart
class SessionMarker {
  SessionMarker({required this.id, required this.videoPath,
                 required this.cursorNdjsonPath, required this.startedAt,
                 required this.width, required this.height, required this.fps});
  final String id;
  final String videoPath;
  final String cursorNdjsonPath;
  final DateTime startedAt;
  final int width, height, fps;
  Map<String, dynamic> toJson();
  static SessionMarker fromJson(Map<String, dynamic>);
}

class SessionMarkerStore {
  SessionMarkerStore({required this.path});
  final String path;
  Future<List<SessionMarker>> load();
  Future<void> add(SessionMarker marker);
  Future<void> remove(String id);
}
```

**Atomic update pattern:** both `add` and `remove` read → mutate → write to `<path>.tmp` → `File.rename(.tmp, path)`. POSIX rename is atomic, so the marker file is either fully written or untouched — never half-written.

**Lifecycle integration:**
- `RecordingController.startRecording`: write the marker immediately after `outputPath` is computed and BEFORE the native start call.
- `RecordingController.stopRecording`: remove the marker AFTER the native writer finalises and after the post-stop `.cursor.json`/`.meta.json` sidecars are written.
- `RecordingController._handleError`: also remove the marker — the user pressed Stop but native failed; not a recovery candidate.

### 3. `CursorCheckpointer`
`packages/screen_recorder/lib/state/cursor_checkpointer.dart` (new)

```dart
class CursorCheckpointer {
  CursorCheckpointer({required this.ndjsonPath});
  final String ndjsonPath;
  Future<void> start();
  void add(CursorPosition pos);
  Future<void> stop();
  static Future<List<CursorPosition>> readAll(String ndjsonPath);
}
```

Wire format, one position per line:
```
{"t":1234,"x":120.5,"y":340.0,"buttons":1}
{"t":1250,"x":121.0,"y":342.0,"buttons":0}
```

`t` = ms since session start (already how `CursorPosition` tracks time). `buttons` is the click bitmask.

**Flush policy:** every 5 s, on 256-entry buffer fill, or on `stop()`. Buffer is `List<String>` of pre-encoded JSON lines; flush is `File.writeAsString(buf.join('\n') + '\n', mode: FileMode.append, flush: true)` — `flush: true` forces `fsync` so data hits disk.

**Wiring in `RecordingController.startRecording`:**
```dart
_cursorCheckpointer = CursorCheckpointer(ndjsonPath: '$outputPath.cursor.ndjson');
await _cursorCheckpointer!.start();
_cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen((pos) {
  _cursorRecording?.addPosition(pos);
  _cursorCheckpointer?.add(pos);
});
```

In `stopRecording`, after the existing `.cursor.json` save:
```dart
await _cursorCheckpointer?.stop();
await File(ndjsonPath).delete();   // NDJSON is recovery-only
```

### 4. `RecoveryService`
`packages/screen_recorder/lib/state/recovery_service.dart` (new)

```dart
class RecoveryCandidate {
  final SessionMarker marker;
  final int videoBytes;
  final Duration estimatedDuration;
}

class RecoveryService {
  RecoveryService({required this.markerStore, required this.ffmpeg});
  final SessionMarkerStore markerStore;
  final Ffmpeg ffmpeg;

  Future<List<RecoveryCandidate>> scan();
  Future<String> recover(RecoveryCandidate, RecordingHistoryStore);
  Future<void> discard(RecoveryCandidate);
}
```

`scan` reads markers, filters those whose video file is missing or zero bytes (removing the stale marker as a side effect), and computes a duration estimate from the meta-sidecar's last checkpoint if present, otherwise from `videoBytes / (width*height*fps*0.07)` (rough H.264-passthrough rate).

**Re-mux command:**
```
ffmpeg -y -i partial.mp4 -c copy -f mp4 -movflags +faststart recovered.mp4
```
- `-c copy` → no re-encode; <1 s for typical clips.
- `-movflags +faststart` → moov at the front for fast playback.
- Trailing partial fragment is discarded automatically by ffmpeg's demuxer.

`recover` flow:
1. Re-mux `<id>.mp4` → `<id>.recovered.mp4`.
2. Read `<id>.cursor.ndjson` via `CursorCheckpointer.readAll`, build a `CursorRecording`, save as `<id>.recovered.mp4.cursor.json`.
3. Write `<id>.recovered.mp4.meta.json` with the re-muxed file's actual duration (from `ffprobe`).
4. Append to `RecordingHistoryStore`.
5. Delete the partial files (`<id>.mp4`, `<id>.cursor.ndjson`).
6. Remove the marker.

`discard` deletes the partial video + cursor NDJSON + any sidecars and removes the marker.

`Ffmpeg` is the facade introduced by remediation Plan A (`packages/slipreel_engine/lib/export/ffmpeg.dart`); reuse it here.

**Lifecycle:** in `main()`, between `permissionsController.refreshAll()` and `runApp`:
```dart
final markerStore = SessionMarkerStore(
  path: p.join((await getApplicationSupportDirectory()).path, 'current_sessions.json'),
);
final recoveryService = RecoveryService(markerStore: markerStore, ffmpeg: Ffmpeg());
final recoveryCandidates = await recoveryService.scan();
```

`recoveryCandidates` is passed into `MyApp` as a new constructor parameter (alongside `onboardingDone`). If non-empty, `_MyAppState` shows `RecoveryModal` on the first post-frame after build.

### 5. `RecoveryModal`
`packages/screen_recorder/lib/ui/widgets/recovery_modal.dart` (new)

Mounted on top of whatever `MyApp` routes to (RecordingBar or OnboardingScreen). Renders a list of candidates (max 5 visible, with `+ N older` indicator beyond that). Per-row content: timestamp + estimated duration + `widthxheight · fps` + `[Recover]` + `[Discard]`.

**Per-row actions:**
- `[Recover]` → calls `recoveryService.recover(candidate, historyStore)`; row shows a spinner during ~1 s re-mux, then collapses with `✓ Recovered`.
- `[Discard]` → calls `recoveryService.discard(candidate)` immediately; no confirmation.

**Bottom actions:**
- `[Discard all]` → loops `discard` over remaining rows; toast confirms.
- `[Close]` → dismisses without acting. Markers stay; modal re-appears on next launch.

When every row is acted on OR the user hits Close, the modal closes and the user lands on their original destination. The modal is a strict overlay.

## Data flow

```
RecordingController.startRecording
   │
   ├─ markerStore.add(SessionMarker{ id, videoPath, ndjsonPath, w, h, fps })
   ├─ cursorCheckpointer.start()
   ├─ native start()  → AVAssetWriter (movieFragmentInterval=5s)
   ├─ cursorStream.listen → in-memory CursorRecording + cursorCheckpointer.add
   └─ duration timer ticking

[normal stop]
RecordingController.stopRecording
   │
   ├─ native stop()  → finishWriting()
   ├─ cursorRecording.saveToFile(.cursor.json)
   ├─ cursorCheckpointer.stop()
   ├─ delete(ndjsonPath)
   ├─ historyStore.append(...)
   └─ markerStore.remove(id)

[crash mid-recording]
   <process killed>
   ├─ marker still present
   ├─ partial .mp4 has header moov + N complete fragments
   └─ partial .cursor.ndjson has N flushed batches

[next cold launch]
main()
   ├─ recoveryService.scan() → [candidates]
   ▼
MyApp(recoveryCandidates: …)
   │
   ▼ (post-frame)
   if (candidates.isNotEmpty) showDialog(RecoveryModal)

User clicks [Recover] on a row
   │
   ▼
recoveryService.recover(cand, historyStore)
   ├─ ffmpeg -i partial.mp4 -c copy -f mp4 -movflags +faststart recovered.mp4
   ├─ CursorCheckpointer.readAll(ndjson) → CursorRecording.saveToFile(.cursor.json)
   ├─ ffprobe recovered.mp4 → duration → write .meta.json
   ├─ historyStore.append(...)
   ├─ delete partial.mp4, ndjson
   └─ markerStore.remove(id)
```

## Error handling / edge cases

| Scenario | Behavior |
|---|---|
| Re-mux fails (corrupt fragment, ffmpeg missing) | Row shows `✗ Couldn't recover` + `[Discard]`. Original partial left in place. `AppLogger.platform.e` logs ffmpeg stderr. |
| Marker points at a missing video file | Filtered out by `scan` and the marker is removed. No UI. |
| Marker present but video is zero bytes | Same as above. |
| Marker present but `.cursor.ndjson` missing | Recovery proceeds with video + audio only; no cursor data. |
| User clicks Recover, mid-recovery clicks Close | In-flight `recover()` future allowed to complete; marker removed on completion. Next launch sees no candidate. |
| Two recovery sessions race (debugger relaunch) | `SessionMarkerStore` uses atomic rename; second launch's scan sees a consistent snapshot. |
| User paused, then crashed | Sub-project A's `pausedOffset` is gone (was native memory). Recovered MP4 ends at the last sample before pause. Recovered duration ≈ pre-pause elapsed. |
| `SessionMarkerStore.add` throws (disk full) | `RecordingController` logs and proceeds anyway — recording is more important than crash resilience. Recording will not be recoverable; correct priority. |
| `RecoveryService.scan` throws | Treated as no candidates; logged. App boots normally. |
| Modal shown while onboarding is on screen | Modal sits over onboarding. Dismissal returns user to onboarding. Onboarding state unaffected. |
| `movieFragmentInterval` produces a fMP4 that `video_player` chokes on | Belt-and-suspenders: detect at recovery via `ffprobe`; on failure, row shows `✗ Couldn't recover`. video_player handles fMP4 in practice. |
| Recording crashed during the first 5 s (no full fragment) | Only upfront `moov` exists; ffmpeg re-mux produces zero-duration output. Row filtered at recovery (`recoveredDuration < 1 s`) and partial discarded. |

## Testing

**Unit / state:**
- `session_marker_test.dart` — add/remove/load round-trip; atomic rename survives simulated mid-write interruption; load defaults to empty list when file missing or malformed.
- `cursor_checkpointer_test.dart` — add + 5 s timer → file contains a line per position; 256-position burst forces a defensive flush; stop() flushes + closes; readAll() round-trips.
- `recovery_service_test.dart` — fakes for `SessionMarkerStore` and `Ffmpeg`; scan filters missing-file markers; scan removes them; recover sequences re-mux + cursor conversion + history append + marker remove; discard deletes files + removes marker.

**Widget:**
- `recovery_modal_test.dart` — renders rows; Recover triggers service stub; Discard triggers service stub; "Discard all" loops; "Close" dismisses without action.

**Integration:**
- `recording_state_marker_test.dart` — `startRecording` writes a marker; `stopRecording` removes it; `_handleError` removes it. Uses a fake `SessionMarkerStore`.

**Manual on-device:**
1. Start a recording, wait 15 s, force-kill the app. Relaunch → modal with one row, ~15 s. Click Recover → file appears in Recents and plays back cleanly.
2. Same but kill within 3 s → no candidate (filtered as too-short).
3. Same as (1) but pause at 10 s, force-kill at 14 s while paused → recovered duration ≈ 10 s.
4. Force-kill twice across two launches → modal shows two rows.

## Out of scope

- Editor project-state recovery — the editor isn't open during recording.
- Cross-platform — Win/Linux ignored as elsewhere.
- Settings toggle to disable recovery — always on; cost is trivial.
- Persistent Recovery-history Settings entry for very old crashed sessions — future polish.
- Auto-recover (no modal) — explicitly excluded by the brainstorm decision.
- macOS Notification Center notification on recovery completion — modal is enough.

## Success criteria

- A force-kill 30 s into a recording produces a candidate on next launch; clicking Recover lands a clean MP4 of ~30 s in Recents that plays in the editor and exports through ffmpeg without errors.
- Two crashes across two launches produce two candidates; user can decide per-row.
- A clean Stop produces zero candidates on next launch.
- A first-run user with no prior recordings sees no modal.
- `melos run analyze --no-select` clean; `melos run test --no-select` green; xcodebuild SUCCEEDED.
