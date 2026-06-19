# Settings → Global App Preferences (Phase 1) — Design

**Date:** 2026-06-19
**Issue:** [#2 Rework Settings screen into focused global app preferences (Phase 1)]
**Status:** Approved (brainstorming complete; ready for implementation plan)

## Summary

Rework the Settings screen from a per-clip "Frame Settings" editor into a
focused **global app preferences** screen. Remove the duplicated frame-styling
controls (they live in the editor inspector's Background tab) and the dev-only
Alert demo. The recording-bar gear menu becomes the single home for the
slimmed-down Settings screen. Add Permissions, Default save location, and
Updates & About sections.

## Goals

- Settings shows only global app preferences — no per-clip frame styling, no
  alert demo.
- Per-clip frame styling stays fully available via the inspector Background tab
  (unchanged).
- Permissions section reflects live status and can re-request / open System
  Settings.
- A configured default save location is honored by exports (pre-fills the save
  dialog) and recordings (auto-saves there).
- Settings no longer references a non-persisting `_barFrame`.

## Non-goals

- Native rebindable hotkeys (Phase 2, separate issue). Phase 1 shows shortcuts
  as a polished **read-only** reference.
- Auto-update implementation (#1). The "Check for updates" entry is a stub.
- Changing the inspector Background tab or the `WindowFrame` model.

## Locked decisions (from brainstorming)

1. **Default save location → exports PRE-FILL the dialog.** When a default
   folder is set, the export Save dialog still opens (user confirms/renames) but
   is pointed at the default folder via `initialDirectory`. Recordings auto-save
   to the default folder (replacing the current `~/Documents` default).
2. **App version via `package_info_plus`** (new dependency) read at runtime.
3. **Settings entry point: recording-bar gear only.** The playback-editor
   "Frame settings" button + `_openFrameSettings` route are removed. (Noted:
   Settings becomes reachable only from the bar gear; adding an editor entry
   later is trivial.)

## Architecture

### 1. `GlobalPreferences` store + controller (new)

Mirror the existing `RecordingSettingsStore` / `RecordingSettingsController`
pattern (`state/recording_settings_store.dart`, `recording_settings_controller.dart`).

- `state/global_preferences_store.dart`:
  - `GlobalPreferences` immutable model: `String? defaultSaveLocation`
    (absolute folder path; null = "ask each time / Documents"). `copyWith`,
    `toJson`, `fromJson`, `static const defaults`.
  - `GlobalPreferencesStore({required String path})` with `load()` /
    `save(GlobalPreferences)` — JSON sidecar under
    `getApplicationSupportDirectory()` (same dir as recording settings).
- `state/global_preferences_controller.dart`:
  - `GlobalPreferencesController extends StateNotifier<GlobalPreferences>` with
    `setDefaultSaveLocation(String? path)` (immediate `state =`, async
    `store.save`).
  - `globalPreferencesControllerProvider` =
    `StateNotifierProvider<GlobalPreferencesController, GlobalPreferences>`,
    overridden in `main.dart` with the loaded initial value + store path (same
    init flow as recording settings).

### 2. `SettingsScreen` rewrite

`ui/screens/settings_screen.dart` becomes a self-contained
`ConsumerStatefulWidget` (no `frame` / `onChanged` params). Title: "Settings".
Single `SingleChildScrollView` with sectioned cards using `context.palette.*`
and the existing section-title + card styling. Sections in order:

1. **Recording defaults** — countdown ToggleButtons (carry over
   `_buildCountdownPicker`, `recordingSettingsControllerProvider`).
2. **Appearance** — theme-playground `ListTile` → `ThemePlaygroundScreen`
   (carry over as-is).
3. **Permissions** — for each of `screenRecording`, `microphone`, `camera`,
   `accessibility`: a `PermissionStatusRow` (label + subtitle + status action).
   `refreshAll()` is called when the screen opens; Grant calls `request(kind)`;
   denied/restricted shows "Open System Settings". Driven by
   `permissionsControllerProvider`.
4. **Default save location** — a card showing the current folder (or
   "Ask each time · ~/Documents" when null), a "Choose…" button
   (`getDirectoryPath()` from `file_selector`), and "Reset" (sets null).
5. **Keyboard shortcuts** — polished read-only reference (carry over
   `_buildShortcutsCard`: ⌘⇧1 / ⌘⇧2 / ⌘⇧P).
6. **Updates & About** — app name + version+build (`package_info_plus`), a
   stubbed "Check for updates" row (disabled / no-op for now), and a single
   "Website" `ListTile` opening `https://slipreel.app` via `url_launcher`
   (already a dependency; used by `permission_denied_sheet.dart`). The exact
   website URL is easily changed; no other links in Phase 1 (YAGNI).

**Removed:** template selector, padding/corner-radius/shadow sliders, color
picker, current-frame info card, and the entire Alert demo section + its
imports (`app_alerts`, `window_frame`).

### 3. Shared `PermissionStatusRow` widget (targeted refactor)

Extract the existing private `_PermissionRow` + `_RowAction` from
`ui/screens/onboarding/pages/permissions_page.dart` into
`ui/widgets/permission_status_row.dart` (public `PermissionStatusRow`).
Onboarding and Settings both consume it. Behavior preserved: granted → check
icon; denied/restricted → "Open System Settings"; notDetermined/unsupported →
"Grant". Onboarding is updated to use the shared widget (no behavior change).

### 4. Entry points

- `ui/bar/recording_bar_screen.dart` (`_onGearTap`, the `'settings'` case,
  ~`:268`): open `_openPanel(const SettingsScreen())`. Remove the `_barFrame`
  field (`:40`) and its usage.
- `ui/screens/playback_screen.dart`: remove `_openFrameSettings`
  (~`:1670`) and the toolbar button that calls it (~`:2886`).

### 5. Save-location wiring

- **Export:** `services/destination_handlers.dart` `FileSaver._defaultSaveDialog`
  passes `initialDirectory: <defaultSaveLocation>` into `getSaveLocation(...)`.
  The default is read from `globalPreferencesControllerProvider` at the call
  site that constructs/uses `FileSaver` (thread the value in rather than having
  the handler read providers directly, to keep it testable).
- **Recording:** `state/recording_state.dart` (~`:190`) uses
  `defaultSaveLocation ?? getApplicationDocumentsDirectory().path` for the
  output path.
- **Missing/deleted folder:** if the configured path no longer exists, fall
  back to Documents (export dialog still opens; recording writes to Documents).

### 6. Dependency

Add `package_info_plus` to `packages/screen_recorder/pubspec.yaml`.

## Data flow

```
Settings screen (ConsumerStatefulWidget)
  ├── recordingSettingsControllerProvider  (countdown)
  ├── appPaletteControllerProvider          (theme link)
  ├── permissionsControllerProvider         (status + request)
  └── globalPreferencesControllerProvider   (default save location)

defaultSaveLocation
  ├── export  → FileSaver getSaveLocation(initialDirectory: …)
  └── recording → recording_state output path (… ?? Documents)
```

## Error handling

- Folder picker cancelled → no change.
- Configured folder unavailable at use time → fall back to Documents; do not
  crash the export/recording.
- `package_info_plus` unavailable in a test harness → guard the version read so
  widget tests don't fail (show a placeholder).

## Testing

- **`GlobalPreferencesStore`** (pure): load missing → defaults; save → load
  round-trip; malformed JSON → defaults.
- **`GlobalPreferencesController`**: `setDefaultSaveLocation` updates state and
  persists; setting null clears it.
- **Export save dialog**: with a default set, `getSaveLocation` receives the
  `initialDirectory` (inject a fake/captured save-dialog fn into `FileSaver`).
- **Recording output path**: with a default set, the path is under the default
  folder; with null/unavailable, under Documents (test the pure path-resolution
  seam).
- **`PermissionStatusRow`** widget test: renders the right action per status;
  tapping "Grant" invokes the callback.
- **Settings screen** widget test: shows the global sections; does NOT show
  frame-styling controls or the Alert demo.

## Out of scope / follow-ups

- Phase 2: native rebindable hotkeys (`HotkeyManager.swift`).
- #1: real auto-update behind the stubbed "Check for updates".
