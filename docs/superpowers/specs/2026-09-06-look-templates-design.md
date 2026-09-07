# Look Templates — Design

Date: 2026-09-06
Status: Approved design, not yet implemented
Branch: `feat/look-templates`
Related: `2026-05-25-audio-capture-microphone-design.md`,
`2026-05-26-system-audio-design.md` (both chose "off each launch" for the
capture toggles; §7 of this spec reverses that decision).

## 1. Goal

Stop re-dialing the same editor settings on every recording. The user picks a
named **look template** before recording (or applies one in the editor), and the
recording opens already styled: frame, wallpaper, padding, cursor, motion, output
aspect, overlays, caption style, and default zoom look.

Separately, the capture-side toggles (microphone, system audio, camera) and the
export settings become **"last used"**: they persist across launches but are not
part of a template.

## 2. Decisions (from brainstorming)

| Question | Decision |
|---|---|
| What a template carries | Editor look only. No timeline content, no capture settings, no export settings. |
| Capture toggles (mic, system audio, camera) | Persist last-used across launches, outside templates. |
| Export settings (format, resolution, destination) | Already last-used via `ExportSettingsStore`; unchanged. |
| Capture-side choices (source mode, countdown) | Source mode is an action, not a setting; countdown already persists. Nothing to add. |
| How templates are created | From the editor: "Save as template" snapshots the current project's look. |
| Where templates are picked | Recording bar (seeds new recordings) and editor inspector (applies to an open recording). |
| Existing zooms on apply | Restyled to the template's default zoom look (same as "Apply to all"). |
| Starter content | Three built-ins (Clean, Showcase, Minimal), read-only, duplicable, plus user templates. |
| Linkage | Copy on apply. A project never tracks which template it came from; updating a template never touches earlier recordings. |

## 3. Non-goals (v1)

- Import/export of template files.
- Template thumbnails or previews.
- Linking a project to its template, or a "modified from template" indicator.
- Template management in the Settings screen.
- Per-template export or capture settings.
- Enforcing unique template names.

## 4. Data model (engine package, `slipreel_engine`)

### 4.1 `EditorLook`

Immutable value class holding exactly the fields a template carries. Grouped
for documentation; the class is flat.

- **Frame chrome**: `windowFrame` (wallpaper, padding, corners, shadow, border,
  inset, background blur, and the device-frame fields `deviceFrameId`,
  `deviceFrameColor`, `deviceFrameAdjustSize`).
- **Cursor**: `cursorSize`, `cursorStyle`, `cursorClickEffect`, `cursorShadow`,
  `clickSpring`, `cursorPostProcess`, `hideCursorOverlay`, `cursorDelay`.
- **Motion**: `screenAnimationConfig`, `cursorAnimationConfig`, `motionBlur`,
  `cursorMovementBlur`, `screenMovementBlur`, `screenZoomBlur`.
- **Layout and overlays**: `outputAspect`, `keystrokeOverlay`, `cameraSettings`,
  `captionStyle`, `defaultZoomLook`.

Excluded on purpose: `timeline` (per-recording content), `timelineScale` and
`pendingScaleAnchor` (transient UI state).

API:

- `EditorLook.fromProject(EditorProjectState)` — snapshot.
- `EditorLook.defaults()` — equals `fromProject(EditorProjectState.defaults())`.
- `toJson()` / `EditorLook.fromJson(Map)` — each field uses the serializer it
  already has on `EditorProjectState` (same key names). Missing keys fall back to
  the default value, mirroring `EditorProjectState.fromJson`'s per-section
  leniency.
- `copyWith(...)`, `==`, `hashCode`.

`EditorProjectState` gains one method:

- `EditorProjectState withLook(EditorLook look)` — copy with every look field
  replaced; timeline, timelineScale, and pendingScaleAnchor untouched.

Project state stays flat. No existing call site changes.

### 4.2 `LookTemplate`

```
LookTemplate {
  String id;          // built-ins: 'builtin.clean' | 'builtin.showcase' | 'builtin.minimal'
                      // user: generated (uuid-like, time + random suffix)
  String name;
  bool builtIn;
  EditorLook look;
  DateTime updatedAt; // UTC
}
```

`id` is the identity. Names are free text and need not be unique.

### 4.3 Built-ins

Constructed in code, never written to disk. All non-frame, non-zoom-look fields
equal `EditorLook.defaults()`.

| id | name | windowFrame | defaultZoomLook |
|---|---|---|---|
| `builtin.clean` | Clean | `WindowFrame.rounded()` | `ZoomLook.classic` |
| `builtin.showcase` | Showcase | `WindowFrame.modern()` | `ZoomLook.showcase` |
| `builtin.minimal` | Minimal | `WindowFrame.minimal()` | `ZoomLook.flat` |

Clean equals today's blank slate, so there is no separate "Default" entry. It is
the fallback selection whenever the selected template is missing.

## 5. Storage (app package, `screen_recorder`)

### 5.1 `LookTemplateStore`

File: `<appSupport>/slipreel/look_templates.json`. Modelled on
`ExportSettingsStore`.

```
{
  "schemaVersion": 1,
  "selectedTemplateId": "builtin.clean",
  "templates": [
    { "id": "...", "name": "...", "updatedAt": "...", "look": { ...EditorLook JSON... } }
  ]
}
```

Only user templates are stored. `selectedTemplateId` may reference a built-in.

Behaviour:

- Atomic writes: write `*.tmp`, then rename. Writes serialized through an
  internal queue.
- Missing or empty file: empty template list, selection `builtin.clean`.
- Corrupt file (JSON parse failure or wrong top-level shape): rename it to
  `look_templates.json.corrupt-<unix-millis>`, log a warning, continue with an
  empty list. Never overwrite a corrupt file in place.
- One template entry fails to parse: skip that entry, keep the rest, log once
  per load.
- `schemaVersion` greater than supported: refuse to load (built-ins only), log,
  and refuse to write for the rest of the session so a downgrade never clobbers
  a newer file.
- Unknown `selectedTemplateId` (deleted or from a newer build): fall back to
  `builtin.clean`.

### 5.2 `LookTemplateController` (Riverpod `StateNotifier`)

State: `{ List<LookTemplate> all, String selectedId }` where `all` is built-ins
first (fixed order Clean, Showcase, Minimal) followed by user templates sorted by
name, case-insensitive.

Operations (all write-through to the store; in-memory state only advances after
a successful write):

- `select(id)`
- `saveNew(name, EditorLook) -> LookTemplate`
- `update(id, EditorLook)` — rejects built-ins.
- `rename(id, name)` — rejects built-ins.
- `duplicate(id) -> LookTemplate` — works for built-ins; new name is
  `"<name> copy"`.
- `delete(id)` — rejects built-ins; if `id` was selected, selection falls back
  to `builtin.clean`.

Provider wiring follows the existing `main()` override pattern
(`lookTemplateStoreProvider`, `lookTemplateControllerProvider`).

## 6. Applying a template

### 6.1 `EditorProjectController.applyLook`

```
void applyLook(EditorLook look, {Size videoSize = Size.zero})
```

Device-frame fields (`deviceFrameId`, `deviceFrameColor`,
`deviceFrameAdjustSize`) are intrinsic to a specific device recording (chosen in
the Device tab or auto-matched at import), not a transferable look, so a template
never carries them. This is enforced by preserving the recording's current
device-frame fields and taking everything else from the template's frame — a
uniform rule that needs no capture-kind flag and no aspect-compatibility check.
On a non-device recording the current fields are null, so no phone bezel can leak
in from a template saved on a device recording.

One undoable state change:

1. **Resolve the window frame:**
   ```dart
   final cur = current.windowFrame;
   final resolvedFrame = look.windowFrame.copyWith(
     deviceFrameId: cur.deviceFrameId,
     deviceFrameColor: cur.deviceFrameColor,
     deviceFrameAdjustSize: cur.deviceFrameAdjustSize,
     clearDeviceFrame: cur.deviceFrameId == null,
   );
   final resolvedLook = look.copyWith(windowFrame: resolvedFrame);
   ```
2. `state = state.withLook(resolvedLook)`.
3. Restyle every zoom on the active track with `resolvedLook.defaultZoomLook`
   via the existing apply-to-all path, including `_enforce3DPaddingFloor`.

Undo: `EditorHistoryController` already coalesces the state publishes from steps
2–3 into a single history entry, so one Cmd-Z (or the toast's Undo) reverts the
whole apply.

### 6.2 Seeding a fresh recording

`EditorProjectStore.load({required Duration videoDuration, EditorProjectState? seed})`
uses `seed ?? EditorProjectState.defaults()` in every branch that today uses
`defaults()` (missing sidecar, empty sidecar, corrupt sidecar). Sidecars that
parse are unaffected.

The playback screen builds the seed as
`EditorProjectState.defaults().withLook(selectedTemplate.look.withoutDeviceFrame())`.
A template's look can carry a `deviceFrameId` when it was saved while a device
recording was open, so the seed strips the device-frame fields via
`EditorLook.withoutDeviceFrame()` — the same "a template never transfers a device
bezel" rule the apply path enforces (§6.1). This keeps the seed from blocking a
fresh device recording's own auto-match (guarded by `deviceFrameId == null`) or
stamping a phone bezel onto a Mac capture. Device recordings then set their own
frame through the existing auto-match/Device-tab path at load.

Recordings opened from Recents with an existing sidecar are untouched. A Recents
recording with no sidecar (old or imported) also receives the selected template;
this is the simplest rule and is not treated as a special case.

### 6.3 Snapshotting

- **Save as new**: `EditorLook.fromProject(state)` with device-frame fields
  included as-is.
- **Update**: same snapshot; overwrites the named template's `look` and
  `updatedAt`.

Neither touches the project, and the project does not record its source
template.

### 6.4 Selection persistence

Picking in the bar and applying in the editor both call `select(id)`. Selection
survives launches via the store.

## 7. Capture-side "last used" persistence

Reverses the "off each launch" launch default chosen in the microphone and
system-audio specs. Those specs listed persistence as a later tweak.

### 7.1 Storage

`RecordingSettings` (app package, `recording_settings_store.dart`) gains three
nullable fields serialized with the configs' existing `toJson`/`fromJson`:

```
{ "countdownSeconds": 3, "microphone": {...} | null, "systemAudio": {...} | null, "camera": {...} | null }
```

A missing key means off, so existing files load unchanged. No schema version is
added to this file; it has none today and the change is additive.

### 7.2 Restore and write-through

`MicrophoneController`, `SystemAudioController`, and `CameraController` accept
an `initial` value from the loaded settings and write through to
`RecordingSettingsStore` on `set`, the same pattern the countdown uses. Their
"in-memory only" doc comments are updated.

### 7.3 Missing device

- **Microphone**: the native mic level monitor already refuses a missing UID
  and emits the negative sentinel the bar renders as a problem state. New rule:
  if that sentinel arrives for a **restored** selection before the user has
  touched the mic control this session, the controller clears the selection to
  off and persists that. A selection the user picked this session is left in
  the existing problem state.
- **Camera**: no monitor exists, and the native `CameraCaptureManager.start`
  already falls back to the system default camera when the saved UID does not
  resolve, so a restored camera never blocks a recording. The bar keeps showing
  the saved label until the user re-picks; no new handling is added. The only
  failure is "no camera at all", which surfaces through the existing
  recording-start error path.
- **System audio**: references app bundle ids, not hardware; restored as-is.

### 7.4 Privacy note

Restoring a mic selection opens the microphone for the level meter at launch
while the bar is visible, without a pick this session. Permission has already
been granted for this to work, and the live meter makes it visible. No new
setting is added.

## 8. UI

### 8.1 Recording bar

A `_TemplateControl` chip sits after the mode buttons (Display, Window, Area,
Device) and before the camera/mic/system-audio group, separated by the existing
`_Divider`. It shows a layout icon and the selected template's name, truncated
with an ellipsis at a fixed max width.

Tapping opens a popover menu in the style of the existing gear and mic menus:
built-ins, a divider, then user templates sorted by name, with a check mark on
the selected entry. The bar only picks; no create or edit here. The bar already
re-measures its width when content changes.

### 8.2 Editor inspector

A `TemplateRow` is added above the tab strip in `InspectorPanel`, visible on
every tab.

- **Left**: a dropdown listing the same entries as the bar, labelled by the
  selected template's name. Choosing one calls `applyLook` immediately and
  shows an `AppAlerts` notification with an Undo action ("Applied Showcase."),
  because applying restyles all zooms and must be reversible in one click.
- **Right**: an overflow button with:
  - Save as new template… (name prompt, default "Untitled 1", "Untitled 2", …
    skipping names already in use)
  - Update "Name" (hidden for built-ins)
  - Duplicate
  - Rename… (hidden for built-ins)
  - Delete… (hidden for built-ins; confirmation dialog)

No "modified relative to template" indicator.

### 8.3 Settings screen

No template management in v1.

### 8.4 Analytics

Through the existing capture path, no template names or look contents:

- `template_applied` — `source: bar | editor`, `builtIn: bool`
- `template_saved` — `kind: new | update`
- `template_deleted`

## 9. Error handling summary

| Situation | Behaviour |
|---|---|
| Template file corrupt | Rename aside with timestamp, warn, built-ins only. |
| One entry unparseable | Skip it, keep the rest, warn once. |
| Future schema version | Built-ins only, warn, no writes this session. |
| Selected id unknown | Fall back to Clean. |
| Template applied to any recording | Recording's device-frame fields preserved; no phone bezel transferred. |
| Store write fails | `AppAlerts.error`; in-memory state stays at last successful write. |
| Restored mic device missing | Clear to off and persist (only for restored, untouched selections). |
| Restored camera device missing | Native start falls back to the default camera; bar label stays until re-picked. |

## 10. Testing

### Engine package (`packages/slipreel_engine/test`)

- `EditorLook` JSON round-trip for `defaults()` and for a fully non-default
  look.
- Coverage guard: build an `EditorProjectState` with every look field set to a
  non-default value; `defaults().withLook(EditorLook.fromProject(p))` must equal
  `p` except `timeline`, `timelineScale`, `pendingScaleAnchor`. Adding a project
  field without adding it to `EditorLook` fails this test.
- `applyLook`: restyles all zooms and sets `defaultZoomLook`; strips
  device-frame fields on non-device recordings; keeps the recording's frame when
  the template has none on device recordings; falls back on incompatible aspect;
  single undo step.
- `EditorProjectStore.load` uses `seed` only when no parseable sidecar exists.

### App package (`packages/screen_recorder/test`)

- `LookTemplateStore`: empty load, round-trip, corrupt file renamed aside,
  future schema refused and write blocked, bad entry skipped, no `.tmp` left
  behind.
- `LookTemplateController`: ordering (built-ins first, users by name),
  save/update/rename/delete/duplicate, built-in rejections, selection fallback
  on delete.
- `RecordingSettings` JSON with and without the three new keys; controllers
  restore from `initial` and write through on `set`; mic sentinel clears a
  restored selection but not a user-picked one.
- Widget tests: bar `_TemplateControl` menu lists and selects; inspector
  `TemplateRow` hides Update/Rename/Delete for built-ins and shows them for user
  templates.

Run via `melos test` on macOS (see CI notes in memory: goldens are
`@TestOn('mac-os')`).

## 11. Conventions

- Dark theme tokens via `context.palette.<role>`; `AppAlerts` for panel
  notifications.
- Never run `dart format` on existing files; match style by hand.
- Stage only files touched by this work; other agents may share the checkout.
- PR against `main` (this repo has no `dev` branch).

## 12. Implementation order (for the plan)

1. Engine: `EditorLook`, `withLook`, coverage-guard test.
2. Engine: `applyLook` and `EditorProjectStore.load(seed:)`.
3. App: `LookTemplate`, built-ins, `LookTemplateStore`, `LookTemplateController`, provider wiring.
4. App: capture-side persistence (§7).
5. App: inspector `TemplateRow` (apply, save, update, manage) with undo.
6. App: recording bar `_TemplateControl` and fresh-recording seeding.
7. Analytics events; live verification in the running app.
