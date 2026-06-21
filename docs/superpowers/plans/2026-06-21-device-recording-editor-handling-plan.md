# Device-Recording Editor Handling — Implementation Plan

> **For agentic workers:** Execute task-by-task, TDD, commit per task. Design rationale lives in `docs/superpowers/specs/2026-06-21-device-recording-editor-handling-design.md`.

**Goal:** Make the editor honestly handle iPhone/iPad recordings (no click/cursor/keystroke data): keep manual zoom, but give the Cursor + Shortcuts tabs an accurate "not available" note with disabled controls, and skip/annotate auto-zoom.

**Architecture:** Persist a `bool isDeviceCapture` in the `.meta.json` sidecar at record-stop; the editor reads it (`_isDeviceRecording`) and threads `isDevice` through `InspectorPanel` to the affected tabs + auto-zoom gates.

**Tech Stack:** Flutter, Riverpod, melos monorepo (`slipreel_engine` model + `screen_recorder` UI). Tests: `flutter test` per package; full suite `melos run test`.

---

### Task A1: `isDeviceCapture` on RecordingMetadata

**Files:**
- Modify: `packages/slipreel_engine/lib/models/recording_metadata.dart`
- Test: `packages/slipreel_engine/test/models/recording_metadata_test.dart` (exists — add cases)

- [ ] **Step 1: Failing tests**

```dart
test('round-trips isDeviceCapture', () {
  final m = RecordingMetadata(
    isPureSource: true, recordedAt: DateTime.utc(2026, 6, 21),
    widthPx: 1170, heightPx: 2532, fps: 60, isDeviceCapture: true,
  );
  final back = RecordingMetadata.fromJson(m.toJson());
  expect(back.isDeviceCapture, isTrue);
  expect(m.toJson()['schemaVersion'], 3);
});

test('isDeviceCapture defaults to false when absent (legacy sidecar)', () {
  final back = RecordingMetadata.fromJson({
    'isPureSource': true, 'recordedAt': '2026-06-21T00:00:00Z',
    'widthPx': 1920, 'heightPx': 1080, 'fps': 30, 'schemaVersion': 2,
  });
  expect(back.isDeviceCapture, isFalse);
});
```

- [ ] **Step 2: Run → fail.** `cd packages/slipreel_engine && flutter test test/models/recording_metadata_test.dart`
- [ ] **Step 3: Implement.** In `recording_metadata.dart`: add field `final bool isDeviceCapture;`, constructor param `this.isDeviceCapture = false,` (default keeps all existing call sites valid). In `toJson` add `'isDeviceCapture': isDeviceCapture,` and bump `'schemaVersion': 3`. In `fromJson` add `isDeviceCapture: json['isDeviceCapture'] as bool? ?? false,`. (The missing-sidecar default in `loadForVideo` already omits it → false.) Also fix the stale first-line path comment.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit.** `feat(metadata): add isDeviceCapture flag (schema v3, default false)`

---

### Task A2: persist `isDeviceCapture` at record-stop

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart` (the `RecordingMetadata(...)` build at stop, ~`:459-481`; `final isDevice = state.selectedSourceKind == RecordingSource.device;` already exists at `:423`)

- [ ] **Step 1:** Add `isDeviceCapture: isDevice,` to the `RecordingMetadata(...)` constructor call at stop. (One-line wiring; correctness is covered by the A1 round-trip + runtime verify — the stop path writes a file via the platform channel and isn't unit-targeted.)
- [ ] **Step 2: Run full suite** `melos run test` → green (no regressions).
- [ ] **Step 3: Commit.** `feat(recording): persist isDeviceCapture in metadata at stop`

---

### Task A3: editor derives `isDevice`; Cursor + Shortcuts tabs show device note + disabled

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (after `_metadata` loads `:632`, add `bool get _isDeviceRecording => _metadata?.isDeviceCapture == true;`; pass to `InspectorPanel` at `:2193`)
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` (add `final bool isDevice;`, forward to cursor + shortcuts tabs)
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/cursor_tab.dart` and `tabs/shortcuts_tab.dart`
- Test: `packages/screen_recorder/test/ui/inspector_device_notes_test.dart` (new)

Shared note constant (define once, e.g. in `inspector_widgets.dart`):
`const kDeviceNote = 'Not available for iPhone/iPad recordings — no cursor, click, or keystroke data is captured over USB.';`

- [ ] **Step 1: Failing widget test** — pump `CursorTab(... isDevice: true)` inside a `ProviderScope` + `MaterialApp`; expect `find.text(kDeviceNote)` (or a `Key('cursor-device-note')`) and the "Hide cursor" toggle disabled (`Switch` with `onChanged == null`). Same for `ShortcutsTab(isDevice: true)`. And `isDevice: false` → note absent.
- [ ] **Step 2: Run → fail.** `cd packages/screen_recorder && flutter test test/ui/inspector_device_notes_test.dart`
- [ ] **Step 3: Implement.** Add `final bool isDevice;` (default false) to `CursorTab` + `ShortcutsTab`. When `isDevice`: render the shared device note at the top of the tab and disable the tab's interactive controls — reuse `InspectorToggle`'s `onChanged: null` disabled style for the toggles, and wrap data-dependent groups in `Opacity(0.4)` + `IgnorePointer` (the `camera_tab.dart:79-96` pattern). Thread `isDevice` through `InspectorPanel` from `playback_screen`.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit.** `feat(editor): device-recording note + disabled cursor/shortcuts tabs`

---

### Task A4: skip auto-zoom + disable restore command + manual-zoom note

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (auto-zoom detect `:674-692`; "Restore default zoom ranges" command `:1206-1225`)
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` (auto-zoom-unavailable note when device)
- Test: extend the A3 test file (or `zoom_context_device_note_test.dart`)

- [ ] **Step 1: Failing widget test** — `ZoomContextInspector` with a device flag → shows `find.text('Auto-zoom isn't available for iPhone/iPad recordings — add zooms manually.')` (or a Key); non-device → absent.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement.** Guard the auto-zoom detection block with `&& !_isDeviceRecording`. Set the "Restore default zoom ranges" command `enabled: … && !_isDeviceRecording`. Add the manual-zoom note in `ZoomContextInspector` when device (thread the flag in alongside Task B3's `videoPath`). Manual zoom placement stays unchanged.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit.** `feat(editor): skip auto-zoom for device recordings + add manual-zoom note`

---

**Done-when:** `melos run test` green; runtime: an iPhone recording opens with the unavailable notes + disabled cursor/shortcuts tabs, and manual zoom still works.
