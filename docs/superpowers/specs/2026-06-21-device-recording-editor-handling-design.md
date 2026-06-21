# Device-Recording Editor Handling — Design

> Sub-project A of the 2026-06-21 editor-polish pair. Sibling: `2026-06-21-manual-zoom-screen-preview-design.md`.

**Goal:** For iPhone/iPad (device) recordings — which carry no click/cursor/keystroke data — make the editor handle the absence honestly: keep manual zoom fully available, but mark the cursor/click/keystroke-dependent features as unavailable with **accurate** notes, instead of today's silent no-op + misleading subtitles.

**Status:** Approved design, pending spec review.

---

## Background / Why

A device recording (`RecordingSource.device`, iPhone/iPad over USB) is captured as a muxed `AVCaptureDevice` — video + optional device audio only. iOS does not expose tap coordinates over USB, so `startDeviceRecording` deliberately skips cursor/keystroke tracking and writes **no** `.cursor.json` / `.keystrokes.json` sidecars (`packages/screen_recorder/lib/state/recording_state.dart:298`, `:423`).

In the editor today, the data-dependent features therefore silently produce nothing — and, worse, the auto-disabled controls show generic/misleading subtitles:

- **Cursor "Hide cursor" toggle** disables (because `_cursorRecording.count == 0`) but the subtitle reads *"Available for recordings made with this version."* (`cursor_tab.dart:121`) — wrong reason.
- **Shortcuts "Show shortcuts" toggle** disables (`_keystrokeRecording.count == 0`) with subtitle *"No keystroke data — record with Accessibility enabled."* (`shortcuts_tab.dart:52`) — implies enabling Accessibility would help, which is false for a device recording.
- **Auto-zoom-on-click** pre-population silently does nothing.

There is currently **no reliable way** for the editor to know a recording is a device recording — it's only *inferred* by absent data, which is fragile (a normal recording where the user never clicked also has no clicks; it does, however, still have cursor *movement* positions, whereas a device recording has zero).

Key insight: the disable machinery already exists. The work is (1) a reliable device flag and (2) making the notes device-accurate — this is smaller than a from-scratch gating system.

## Design

### 1. Persist a device flag in metadata
Add `bool isDeviceCapture` to `RecordingMetadata` (`packages/slipreel_engine/lib/models/recording_metadata.dart`):
- Serialized in `toJson` / `fromJson`; bump schema version 2 → 3.
- `fromJson` defaults the field to `false` when absent → backward-compatible; pre-existing recordings read as non-device.
- Written at stop time (`recording_state.dart` ~`:459-481`), reusing the already-computed `final isDevice = state.selectedSourceKind == RecordingSource.device;` (`:423`): `isDeviceCapture: isDevice`.

Rationale for a `bool` over a full `RecordingSource` enum: the only current need is "is this a device recording," and `RecordingMetadata` lives in `slipreel_engine` while `RecordingSource` lives in `screen_recorder_platform_interface` — a `bool` avoids adding a cross-package enum dependency (YAGNI; widen to a source enum later if window/area ever need distinguishing).

> Note: device recordings made **before** this change won't carry the flag and will be treated as non-device. Acceptable — the device feature only just shipped; re-record to pick it up.

### 2. Derive `isDevice` in the editor
In `playback_screen.dart`, after `_metadata` loads (`:632`): expose `bool get _isDeviceRecording => _metadata?.isDeviceCapture == true;`.

### 3. Gate the cursor + shortcuts tabs with device-accurate notes
Thread `isDevice` into `InspectorPanel` (`playback_screen.dart:2193`) alongside the existing `canHideCursor` / `hasKeystrokeData` props, down to the tabs.

For a device recording, **both the Cursor tab and the Shortcuts tab are moot in their entirety** (no cursor positions → no cursor overlay to style/hide, no click events → no click effects/ripples ever fire; no keystrokes → nothing to show). So:

- **Cursor tab** (`cursor_tab.dart`): when `isDevice`, show a single top-of-tab note and disable the tab's controls (greyed, non-interactive).
- **Shortcuts tab** (`shortcuts_tab.dart`): same.

Note copy (shared): **"Not available for iPhone/iPad recordings — no cursor, click, or keystroke data is captured over USB."**

Reuse established patterns:
- `InspectorToggle` already renders disabled + an explanatory subtitle when `onChanged: null` (`inspector_widgets.dart:376-451`).
- For disabling a whole group, the `Opacity(0.4)` + `IgnorePointer(ignoring: true)` pattern already used for inapplicable controls (`camera_tab.dart:79-96`), with the note rendered above the greyed group.

The exact widget structure (per-control vs whole-tab wrap) is a plan-level detail; the requirement is: **controls visibly disabled + one clear device note per affected tab.**

### 4. Skip auto-zoom + add a note
- Guard auto-zoom detection with `&& !isDevice` (`playback_screen.dart:674-692`). It already no-ops on empty clicks; the guard makes intent explicit and avoids the metadata-gated detection path entirely.
- Command-palette **"Restore default zoom ranges"**: `enabled: … && !isDevice` (`playback_screen.dart:1206-1225`).
- Add a brief note where zoom is surfaced (zoom inspector/lane) so the user knows to add zooms by hand: **"Auto-zoom isn't available for iPhone/iPad recordings — add zooms manually."** (Lowest-priority note since auto-zoom is invisible anyway; exact placement is plan-level.)

### 5. Manual zoom stays available
No change. Manual zoom placement does not depend on click data — for a device recording it becomes the only zoom path, which is exactly why sub-project B (frame preview under the placement box) matters here.

## Components / Files
- **Modify** `packages/slipreel_engine/lib/models/recording_metadata.dart` — add `isDeviceCapture`, bump schema, round-trip.
- **Modify** `packages/screen_recorder/lib/state/recording_state.dart` — write `isDeviceCapture` at stop.
- **Modify** `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — derive `isDevice`; thread to `InspectorPanel`; guard auto-zoom + command.
- **Modify** `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` — accept + forward `isDevice`.
- **Modify** `cursor_tab.dart`, `shortcuts_tab.dart` — device-aware disable + note.
- **Modify** `zoom_context_inspector.dart` (or the zoom lane) — auto-zoom-unavailable note.

## Testing
- **Unit:** `RecordingMetadata.toJson`/`fromJson` round-trip with `isDeviceCapture` true/false; JSON missing the field → defaults to `false` (backward-compat).
- **Widget:** Inspector with `isDevice = true` → cursor & shortcuts controls disabled and the device note present; `isDevice = false` → normal enabled behavior.
- **Behavior:** auto-zoom detection not invoked when `isDevice` (and "Restore zoom ranges" disabled).
- **Runtime verify:** record an iPhone → open editor → see the notes + disabled cursor/shortcuts, confirm manual zoom still works.

## Out of scope
- Capturing real taps from the phone (infeasible over USB — would need the phone's on-screen touch indicator or an on-device companion app).
- Any change to the capture pipeline beyond the metadata field.
- Hiding (vs disabling-with-a-note) the affected tabs — the user explicitly wants the explanatory notes shown.
