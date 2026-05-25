# Compact Recording Bar — Design

**Status:** approved (brainstorm 2026-05-25)
**Topic:** Replace the full-window source-picker screen with a slim floating
control bar as the app's initial UI, plus a native click-to-select picker
overlay for Window/Display.

## Goal

When Slipreel launches, show a **compact, floating, always-on-top bar** (like a
macOS screen-recorder toolbar) instead of a large window. The bar exposes the
record sources and quick access to Recents/Settings, and gets out of the way.
Picking a Window or Display paints a **native overlay onto the real desktop**
windows/screens; the user clicks the target's Record button to start. While
recording, the bar collapses to a small pill. Recents, Settings, and the editor
expand the same window to a normal panel, then it shrinks back to the bar.

## Non-goals (this project)

- Camera, microphone, and system-audio **capture** — no backend exists. These
  appear as **disabled placeholders** only (visual fidelity to the reference,
  wired later).
- "Device" (external iOS device) capture — disabled placeholder.
- Flutter desktop multi-window — explicitly rejected (experimental/unstable);
  we morph a single window instead.

## The bar (Layout A — "mirror the reference")

A horizontal rounded dark bar, left → right:

1. **Circular ✕** — quits the app.
2. *(divider)*
3. **Source modes**, icon-over-label: **Display**, **Window**, **Area**,
   **Device** (Device greyed/disabled with a "coming soon" tooltip).
4. *(divider)*
5. **Disabled A/V placeholders**, icon+label, greyed, "coming soon" tooltip:
   **No camera**, **No microphone**, **No system audio**.
6. *(divider)*
7. **Gear ▾** — opens a menu: **Recent recordings**, **Settings**, separator,
   **Quit Slipreel**.

There is **no Record button on the bar**. Recording is started from the native
picker overlay (Window/Display) or by confirming the region (Area). This keeps
the bar faithful to the reference and short.

Clicking a source mode:

- **Display** → native per-screen overlay (below).
- **Window** → native per-window overlay (below).
- **Area** → existing native region-draw flow (`selectRegion`); confirming the
  region starts recording.
- **Device** → no-op (disabled).

## Native click-to-select picker overlay

Flutter cannot paint over other apps' windows from inside its small bar window,
so the picker is **native**, modeled on the existing `RegionSelector`
(`screen_recorder_macos/macos/Classes/RegionSelector.swift`): one borderless,
transparent `NSWindow` per `NSScreen` at `.screenSaver` level, a custom view
handling mouse, returning the selection to Flutter via a continuation /
method-channel result. Esc or clicking empty space cancels (returns null).

**Data already available:** `SourceCatalog.listSources` returns each window's
on-screen `frame` (x/y/w/h) and `ownerBundleId`, and each display's id/name/size.
App icons are fetched natively from the owning app (`NSRunningApplication` /
`NSWorkspace`) and drawn directly in the overlay — never shipped to Flutter.

### Window mode

For each on-screen window (after the catalog's strict filter — tiny/system
windows already dropped), draw a full-cover overlay positioned over that
window's frame, containing **centered**: the **app icon**, the **window title**,
and a **Record** button. All targets show their controls at rest with a dim
scrim; the window under the cursor fills **blue translucent** with a blue inner
border. The underlying windows stay faintly visible. Clicking a target's Record
(or the target) confirms that window id → start recording.

Overlapping windows: the per-screen overlay view knows all target frames on its
display (in display-local coordinates) and hit-tests **topmost-first** on mouse
move to decide which target is hovered; it draws controls per visible frame.

### Display mode

For each display, one full-screen overlay with the **display name**,
**resolution**, and a **Record** button, centered. Hovered display fills blue.
No app icon. Clicking Record confirms that display id → start recording.

### Coordinate handling

Reuse `RegionSelector`'s convention: overlay windows are created with
`contentRect: screen.frame` in global coordinates (no `screen:` argument).
Window frames from `SourceCatalog` (CG top-left origin) are converted to each
overlay's AppKit (bottom-left) local space; the conversion + topmost hit-test
are **pure functions**, unit-tested (the overlay view itself isn't unit-tested,
mirroring how only `RegionSelectorState` is tested today).

## Window morphing (single window, three modes)

The one Flutter window changes shape via an app-level method channel handled in
the macOS Runner (`macos/Runner/MainFlutterWindow.swift`) — separate from the
recorder plugin. Modes:

| Mode | Window | Used for |
|---|---|---|
| **bar** | small, borderless, transparent bg, `.floating` (always-on-top), draggable (movable by background), sized to the bar (~ fixed height, content width), positioned near top-center on launch | default / idle |
| **pill** | tiny borderless floating window sized to the pill | while recording |
| **panel** | normal resizable window, standard level (not on-top), title bar, centered, comfortable default size (e.g. 1100×720) | Recents, Settings, editor (`PlaybackScreen`) |

Flutter requests a mode through a `WindowModeController` (Riverpod). The native
side applies frame, `level`, `styleMask`, `collectionBehavior`, and
`movableByWindowBackground` per mode and animates the frame change. Closing a
panel view returns to **bar**. The bar's rounded shape requires a transparent
native window background (Flutter paints the rounded bar; corners outside it are
clear).

## Recording lifecycle

bar → (pick source / confirm region) → **start recording** → window switches to
**pill** (pulsing red dot + elapsed `m:ss` + stop). Stop → window switches to
**panel** and pushes the editor (`PlaybackScreen`) — unchanged from today. The
existing `recordingControllerProvider` start/stop and the
`status == completed → PlaybackScreen` navigation are reused; only the host
chrome (bar/pill/panel) and the source-selection entry point change.

## Recents & Settings

Reused as-is. Opening either from the gear menu switches the window to **panel**
and shows the existing `RecentsScreen` / `SettingsScreen`; a back affordance
returns to the bar (window shrinks). The old `RecordingScreen` app-bar actions
that no longer have a home — **"Show all windows" (strict filter)** and
**Refresh** — move into **Settings** (strict filter becomes a setting; the
overlay always reflects current on-screen windows, so an explicit refresh is
unnecessary).

## Permissions & empty states

- **Screen-recording permission denied:** clicking a source mode that needs
  enumeration surfaces the denial by switching to **panel** and showing the
  existing `PermissionCta` (retry). Same detection as today
  (`PERMISSION_DENIED` / localized substrings in `recording_screen.dart`).
- **No windows / no displays on screen:** the overlay shows a centered hint
  ("No windows to record — open one and try again") with Esc to cancel.
- **Picker / region cancelled (Esc):** return to the bar, no state change.

## Component boundaries (files)

**Flutter — `screen_recorder`:**
- Create `lib/ui/bar/recording_bar_screen.dart` — root widget; the new
  `home:`. Watches `WindowModeController` and renders bar / pill / panel content
  (panel hosts Recents/Settings/editor routes).
- Create `lib/ui/bar/recording_bar.dart` — the bar widget: ✕, source modes,
  disabled A/V placeholders, gear ▾ menu. No IO; callbacks out.
- Create `lib/ui/bar/recording_pill.dart` — the pill: red dot, `m:ss` timer,
  stop. Pure presentation given elapsed + onStop.
- Create `lib/state/window_mode_controller.dart` — Riverpod controller holding
  the current `WindowMode` (bar/pill/panel) and calling the native window
  channel. Single source of truth for chrome.
- Create `lib/platform/window_chrome_channel.dart` — thin wrapper over the
  app-level `MethodChannel('slipreel/window')` (`setMode`).
- Modify `lib/main.dart` — `home: RecordingBarScreen()`; remove direct
  `RecordingScreen` home.
- Reuse `RecentsScreen`, `SettingsScreen`, `PlaybackScreen`,
  `recordingControllerProvider`, `PermissionCta`, `RegionTabContent` flow.
- The old `RecordingScreen` (full-window grid picker) is removed once the bar
  covers its responsibilities; the **source-picker subwidgets it owns are
  superseded** by the native overlay for Window/Display.

**Platform interface — `screen_recorder_platform_interface`:**
- Add `Future<PickedSource?> pickSource(RecordingSource kind)` to the platform
  interface + method-channel impl. `PickedSource { RecordingSource kind; String
  id; }` (window id or display id). Returns null on cancel.

**Native — `screen_recorder_macos`:**
- Create `macos/Classes/SourcePickerOverlay.swift` (modeled on
  `RegionSelector`) + `SourcePickerView.swift` (the per-screen drawing/mouse
  view).
- Create `macos/Classes/SourcePickerGeometry.swift` — pure helpers: CG↔AppKit
  frame conversion, topmost-frame hit-test. Unit-tested.
- Add app-icon helper (bundleId → `NSImage`).
- Wire `pickSource` into `ScreenRecorderMacosPlugin` method channel.

**Native — app Runner (`macos/Runner`):**
- `MainFlutterWindow.swift` — register `MethodChannel('slipreel/window')`;
  implement `setMode(bar|pill|panel, {width,height})` applying frame/level/
  styleMask/collectionBehavior/movableByWindowBackground and animating.

## Testing

**Flutter widget/unit:**
- `RecordingBar`: renders 4 source modes; Device + the 3 A/V controls are
  disabled; gear menu lists Recents/Settings/Quit; tapping a mode fires the
  right callback; ✕ fires quit.
- `RecordingPill`: formats elapsed as `m:ss`; stop fires `onStop`.
- `WindowModeController`: transitions (idle→bar, start→pill, stop→panel,
  closePanel→bar) push the expected `setMode` calls through a fake channel.
- `RecordingBarScreen`: in panel mode renders Recents/Settings/editor; back
  returns to bar.

**Native Swift (RunnerTests, following `RegionSelectorStateTests`):**
- `SourcePickerGeometry`: CG→AppKit frame conversion for primary and
  offset/secondary displays; topmost hit-test picks the front window when
  frames overlap; point outside all frames → none.

**Existing behavior preserved:**
- `recordingControllerProvider` start/stop unchanged; completed→`PlaybackScreen`
  navigation unchanged; `RecordingMetadata` save (incl. duration) unchanged.

## Out of scope (v1)

A/V/Device capture; multi-window; per-window live thumbnails in the overlay;
animated 3-2-1 countdown; menu-bar item; remembering last-used source; dragging
the pill. The strict-filter toggle moves to Settings but its semantics are
unchanged.
