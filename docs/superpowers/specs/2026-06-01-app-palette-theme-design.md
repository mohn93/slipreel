# App Palette Theme — Design Spec

**Date:** 2026-06-01
**Status:** Approved, ready for implementation plan.

## Goal

Replace the current `ColorScheme.fromSeed(#6C63FF)`-driven theme with a deliberately-darker, role-based palette system. Three named candidates (Midnight, Carbon, Obsidian) accessible from a Theme Playground screen. Sweep every hardcoded color literal across editor + settings + recents + motion-blur screens onto the new tokens. Add 1px dividers between layout regions (canvas/inspector, canvas/toolbar, body/timeline, AppBar/body) so the UI reads as discrete panels instead of one floating canvas.

## Non-Goals

- **No light theme.** Dark only; the brightness field on the `ColorScheme` is always `Brightness.dark`.
- **No per-screen palette overrides.** One global palette at a time.
- **No animated transition between palettes.** Hard swap on selection. (`AppPalette.lerp` is implemented for future use but not wired through `AnimatedTheme`.)
- **No migration of `RecordingBar` chrome** in this round — it has its own deliberately-tuned 68px bar window theme. Revisit if/when we unify bar + panel chrome.
- **No `AlertPill` color migration.** Alert colors are type-coded (success/error/warning/info), not palette tokens.
- **No semantic-button-color migration.** `Colors.red` / `Colors.green` for destructive / success buttons stay as-is.
- **No golden-image tests.** Codebase convention.

## Architecture Summary

A `ThemeExtension<AppPalette>` carrying named role tokens (`appBackground`, `surfaceLow`, `surfaceElevated`, `surfaceCard`, `dividerSubtle`, `dividerStrong`, `accent`, `accentMuted`, `textPrimary`, `textSecondary`). Three named constants (`AppPalette.midnight/.carbon/.obsidian`). A Riverpod `AppPaletteController` (StateNotifier<PaletteId>) persists the selection to a JSON sidecar at the app-support dir. The root `MaterialApp` watches the controller, rebuilds with the matching palette in `ThemeData.extensions`. A `ThemePlaygroundScreen` provides 3 swatch tiles + a live miniature editor preview + the active palette's raw swatches; selection is live (no Apply button). Every hardcoded color literal across the affected screens migrates to a token read via `context.palette.<role>`. New dividers anchor the editor's regions.

```
AppPaletteStore (JSON sidecar at <appSupport>/app_palette.json)
        │
        ▼
AppPaletteController (Riverpod StateNotifier<PaletteId>)
        │
        ▼
MaterialApp.theme = ThemeData(colorScheme: palette.toColorScheme(), extensions: [palette])
        │
        ▼
context.palette.<role>   ← used by every migrated callsite
```

## Token System

### `AppPalette` ThemeExtension

New file: `packages/screen_recorder/lib/ui/theme/app_palette.dart`.

```dart
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.appBackground,
    required this.surfaceLow,
    required this.surfaceElevated,
    required this.surfaceCard,
    required this.dividerSubtle,
    required this.dividerStrong,
    required this.accent,
    required this.accentMuted,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color appBackground;     // Scaffold background — the darkest tone
  final Color surfaceLow;        // editor backdrop, dim panels
  final Color surfaceElevated;   // AppBar, inspector, timeline tracks
  final Color surfaceCard;       // settings cards, recents cards, chips
  final Color dividerSubtle;     // 1px between regions, inside panels
  final Color dividerStrong;     // around modal dialogs, important boundaries
  final Color accent;            // primary action
  final Color accentMuted;       // tinted backgrounds, hover states
  final Color textPrimary;       // body text
  final Color textSecondary;     // captions, helper text

  @override
  AppPalette copyWith({ /* every field as nullable */ });

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t);

  /// Derives a Material 3 ColorScheme so M3 widgets that don't read the
  /// extension still match the chosen palette.
  ColorScheme toColorScheme() => ColorScheme.dark(
        background: appBackground,
        surface: surfaceElevated,
        surfaceVariant: surfaceCard,
        primary: accent,
        primaryContainer: accentMuted,
        onBackground: textPrimary,
        onSurface: textPrimary,
        outline: dividerStrong,
        outlineVariant: dividerSubtle,
        brightness: Brightness.dark,
      );

  static const AppPalette midnight = AppPalette(/* hex values below */);
  static const AppPalette carbon = AppPalette(/* hex values below */);
  static const AppPalette obsidian = AppPalette(/* hex values below */);

  static AppPalette byId(PaletteId id) => switch (id) {
        PaletteId.midnight => midnight,
        PaletteId.carbon => carbon,
        PaletteId.obsidian => obsidian,
      };
}

enum PaletteId { midnight, carbon, obsidian }
```

### Initial palette values

These ship as the starting candidates. The playground exists to let the user evaluate and switch; if a candidate reads badly in-app after the implementation lands, we tune the constant — not the architecture.

| Role | Midnight | Carbon | Obsidian |
|---|---|---|---|
| `appBackground` | `#0B0B10` | `#121212` | `#0A0E1A` |
| `surfaceLow` | `#0F0F16` | `#161616` | `#0F1626` |
| `surfaceElevated` | `#13131A` | `#1B1B1B` | `#10162A` |
| `surfaceCard` | `#1A1A23` | `#222222` | `#171F38` |
| `dividerSubtle` | `#22222C` | `#2C2C2C` | `#1F2A48` |
| `dividerStrong` | `#33333F` | `#3A3A3A` | `#2A3A5C` |
| `accent` | `#7C6CFF` | `#8B7CFF` | `#6C63FF` |
| `accentMuted` | `#7C6CFF` @ 18% | `#8B7CFF` @ 18% | `#6C63FF` @ 18% |
| `textPrimary` | `#F2F2F5` | `#EFEFEF` | `#E8ECF5` |
| `textSecondary` | `#9A9AA8` | `#A0A0A0` | `#8B95B0` |

### `context.palette` extension

New file: `packages/screen_recorder/lib/ui/theme/app_palette_context.dart`.

```dart
extension AppPaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}
```

Every migrated callsite reads as `context.palette.appBackground` (instead of `Theme.of(context).extension<AppPalette>()!.appBackground`).

## Persistence

### `AppPaletteStore`

New file: `packages/screen_recorder/lib/state/app_palette_store.dart`. Mirrors the existing `RecordingSettingsStore` / `MotionTuningStore` pattern.

```dart
class AppPaletteStore {
  AppPaletteStore({required this.path});
  final String path;

  static Future<AppPaletteStore> resolveDefault() async {
    final dir = await getApplicationSupportDirectory();
    return AppPaletteStore(path: p.join(dir.path, 'app_palette.json'));
  }

  Future<PaletteId?> load() async {
    // Returns null on: missing file, unreadable, corrupt JSON, or unknown
    // paletteId string. Never throws.
  }

  Future<void> save(PaletteId id) async {
    // Writes {"paletteId": "<id.name>"} to [path]. Errors are swallowed
    // (matches existing stores).
  }
}
```

JSON shape: `{"paletteId": "midnight" | "carbon" | "obsidian"}`. Unknown values → `null` from `load()`.

### `AppPaletteController`

New file: `packages/screen_recorder/lib/state/app_palette_controller.dart`.

```dart
class AppPaletteController extends StateNotifier<PaletteId> {
  AppPaletteController({
    required AppPaletteStore store,
    PaletteId initial = PaletteId.midnight,
  })  : _store = store,
        super(initial);

  final AppPaletteStore _store;

  void select(PaletteId id) {
    state = id;
    unawaited(_store.save(id));
  }
}

final appPaletteControllerProvider =
    StateNotifierProvider<AppPaletteController, PaletteId>(
  (ref) => throw UnimplementedError(
    'Override appPaletteControllerProvider in main.dart with a loaded store',
  ),
);
```

The provider throws by default so a missing override surfaces at startup, not silently as a default Midnight palette.

### Startup wiring (`main.dart`)

In the existing `main()` (alongside the existing `tuningStore`, `recordingSettingsStore`, `onboardingStore` loads):

```dart
final paletteStore = await AppPaletteStore.resolveDefault();
final initialPalette = (await paletteStore.load()) ?? PaletteId.midnight;
```

Then in the existing `ProviderScope(overrides: [...])`:

```dart
appPaletteControllerProvider.overrideWith(
  (ref) => AppPaletteController(store: paletteStore, initial: initialPalette),
),
```

### MaterialApp consumption

The root `App` widget watches the controller and builds the theme from it. The root widget needs to become a `ConsumerWidget` if it isn't already; per the current `main.dart` it already uses Riverpod, so this is a one-import change.

```dart
@override
Widget build(BuildContext context) {
  final selected = ref.watch(appPaletteControllerProvider);
  final palette = AppPalette.byId(selected);
  // ... existing addPostFrameCallback for AppAlerts.attach ...
  return MaterialApp(
    navigatorKey: rootNavigatorKey,
    title: 'Slipreel',
    theme: ThemeData(
      colorScheme: palette.toColorScheme(),
      extensions: [palette],
      useMaterial3: true,
    ),
    // ... rest unchanged
  );
}
```

## Theme Playground Screen

New file: `packages/screen_recorder/lib/ui/screens/theme_playground_screen.dart`. Reached from a "Theme playground" tile under a new "Appearance" section in `settings_screen.dart`.

### Layout (vertical scroll)

1. **Swatch picker row** — three tiles side-by-side, each ~180×120 px. Each tile:
   - Paints a miniature "scaffold + AppBar + card + accent button + 1px divider" arrangement using its candidate palette.
   - Shows the palette name centered below the mini.
   - Active palette: 2 px `accent` border around the tile + a check icon overlay top-right.
   - Tap → dispatches `controller.select(id)`. The whole app re-themes; the tile becomes the new active.

2. **Spacer (24 px) + section title "Preview"**

3. **Miniature editor preview** — a single Card sized ~720×360 px showing:
   - A faux AppBar strip at top using `surfaceElevated`.
   - A Row split 70/30 (canvas / inspector) with `VerticalDivider` between them in `dividerSubtle`.
   - Below the Row, a 1 px `dividerSubtle` then a faux timeline strip (24 px tall, `surfaceElevated` background with a single zoom pill in `accent`).
   - Inside the inspector: a card (`surfaceCard`) holding a labeled slider track and a chip (`accentMuted`).
   - Below the timeline: 3 text samples — one `textPrimary`, one `textSecondary`, one `accent`.

4. **Spacer (24 px) + section title "Tokens"**

5. **Raw swatch grid** — 10 small chips (one per token field), each showing:
   - A 32×32 colored square.
   - The token name (e.g. `appBackground`).
   - The hex value (e.g. `#0B0B10`).

   Grid layout: 5 columns × 2 rows, with text-secondary labels.

### Entry from Settings

In `settings_screen.dart`, just below the existing "Alert demo" section:

```dart
const SizedBox(height: 32),
_buildSectionTitle('Appearance'),
const SizedBox(height: 12),
Container(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  decoration: BoxDecoration(
    color: context.palette.surfaceCard,
    borderRadius: BorderRadius.circular(8),
  ),
  child: ListTile(
    leading: const Icon(Icons.palette_outlined),
    title: Text('Theme playground',
        style: TextStyle(color: context.palette.textPrimary)),
    subtitle: Text('Preview and pick the app theme',
        style: TextStyle(color: context.palette.textSecondary)),
    trailing: const Icon(Icons.chevron_right),
    contentPadding: EdgeInsets.zero,
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ThemePlaygroundScreen()),
    ),
  ),
),
```

## Sweep Map

12 hardcoded literals → 12 token reads. Plus 4 new dividers.

| Current | Files (line numbers approximate) | New |
|---|---|---|
| `Color(0xFF1E1E2E)` | `settings_screen.dart:81`, `recents_screen.dart:99`, `playback_screen.dart:826`, `motion_blur_playground_screen.dart:254/263/269` | `context.palette.appBackground` |
| `Color(0xFF2B2B3D)` | `settings_screen.dart:84/197`, `recents_screen.dart:103`, `playback_screen.dart:829`, `motion_blur_playground_screen.dart:271` | `context.palette.surfaceElevated` |
| `Color(0xFF6C63FF)` | `playback_screen.dart:884/890` | `context.palette.accent` |
| `Color(0xFF181826)` | `playback_screen.dart:937` (gradient top) | `context.palette.surfaceLow` |
| `Color(0xFF0E0E18)` | `playback_screen.dart:942` (gradient bottom) | `context.palette.appBackground` |
| `Color(0xFF2A2A38)` | `inspector_widgets.dart:41` (`InspectorSectionDivider`) | `context.palette.dividerSubtle` |
| `Colors.white12` | `motion_blur_playground_screen.dart:1799/1809` (`Divider(color: ...)`) | `context.palette.dividerSubtle` |
| Border color literals in `settings_screen.dart:282/308` and `inspector_widgets.dart:90` | card outlines | `context.palette.dividerSubtle` |

### New dividers to insert

- **Above the canvas toolbar** in `playback_screen.dart` — between the canvas Container and the `CanvasToolbar` widget (around line 933). 1 px `dividerSubtle`.
- **Between canvas area and inspector panel** — inside the Row at line 929, between the Expanded canvas pane and the `InspectorPanel`. `VerticalDivider(width: 1, thickness: 1, color: context.palette.dividerSubtle)`.
- **Above the timeline** — between the editor content column and `_buildControls()` (around line 1028). `Divider(height: 1, thickness: 1, color: context.palette.dividerSubtle)`.
- **Below the AppBar** on Settings, Recents, Playback, Motion-Blur-Playground screens — 1 px `dividerSubtle`. Most cleanly achieved by setting `appBar.bottom = PreferredSize(child: Container(height: 1, color: ...))`.

### Out of scope

- `recording_bar.dart` chrome — own theme.
- `AlertPill` colors — type-coded.
- `Colors.red` / `Colors.green` semantic buttons — not palette roles.

## Files Created / Modified

**Create:**
- `packages/screen_recorder/lib/ui/theme/app_palette.dart`
- `packages/screen_recorder/lib/ui/theme/app_palette_context.dart`
- `packages/screen_recorder/lib/state/app_palette_store.dart`
- `packages/screen_recorder/lib/state/app_palette_controller.dart`
- `packages/screen_recorder/lib/ui/screens/theme_playground_screen.dart`
- `packages/screen_recorder/test/ui/theme/app_palette_test.dart`
- `packages/screen_recorder/test/state/app_palette_store_test.dart`
- `packages/screen_recorder/test/state/app_palette_controller_test.dart`
- `packages/screen_recorder/test/ui/screens/theme_playground_screen_test.dart`

**Modify:**
- `packages/screen_recorder/lib/main.dart` — load store + initial palette before `runApp`; add provider override; watch controller in App build; build `ThemeData` from palette.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` — add "Appearance" section + Theme playground tile; migrate Scaffold / AppBar / card literals to tokens.
- `packages/screen_recorder/lib/ui/screens/recents_screen.dart` — migrate Scaffold / AppBar literals.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — migrate Scaffold / AppBar / gradient / accent button literals; add 3 new dividers (canvas-toolbar separator, canvas-inspector separator, body-timeline separator) + AppBar bottom divider.
- `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart` — migrate Scaffold / AppBar / Divider literals; AppBar bottom divider.
- `packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart` — migrate `InspectorSectionDivider` color + card-outline border color.

## Testing

### Unit

- `app_palette_test.dart`:
  - `midnight`, `carbon`, `obsidian` are non-null and pairwise unequal.
  - `copyWith(accent: X)` replaces only `accent`.
  - `lerp(other, 0)` equals `this`; `lerp(other, 1)` equals `other`.
  - `toColorScheme()` for each candidate produces a `ColorScheme.dark` with `primary == accent`, `background == appBackground`, `outlineVariant == dividerSubtle`.
- `app_palette_store_test.dart`:
  - `save(midnight)` then `load()` returns `midnight`. Repeat for all three.
  - `load()` on missing file returns `null`.
  - `load()` on `{"paletteId": "garbage"}` returns `null` (no throw).
  - `load()` on non-JSON garbage returns `null`.
- `app_palette_controller_test.dart`:
  - Initial state matches the `initial` constructor arg.
  - `select(carbon)` publishes `carbon` and triggers `_store.save(carbon)` (verified via a fake store recording calls).

### Widget

- `theme_playground_screen_test.dart`:
  - Three swatch tiles render with the right labels (`Midnight`, `Carbon`, `Obsidian`).
  - Tapping a tile fires the controller's `select` with the matching `PaletteId`.
  - The active tile renders a check icon; non-active tiles do not.
  - The miniature editor preview block contains exactly one `VerticalDivider` (canvas/inspector) and at least two horizontal `Divider`s (above timeline, below AppBar).
  - The "Tokens" grid renders 10 chips with non-empty hex labels.
- `app_palette_context_test.dart`:
  - `context.palette` returns the palette installed via `ThemeData.extensions`.

### Manual verification

- Cold launch with empty store → defaults to Midnight; every screen reads correctly.
- Open the playground, tap each candidate → the entire app re-themes live; settings card, recents, editor backdrop, timeline divider all reflect the choice.
- Restart the app → the last picked palette restores.
- Open the editor with a recording. Confirm the new dividers (canvas/toolbar, canvas/inspector, body/timeline) are visible at 1 px and read at all three palettes.

## Open Risks

- **Hot-restart resets in-memory Riverpod state but not the on-disk store.** Behavior on hot-restart: `main()` re-runs, store reloads, palette restores. Identical to a cold launch. No issue.
- **Material 3 widgets that don't honor the extension** — there are some (e.g. `Card`'s default elevation tint). They get a `ColorScheme.dark(...)` derived from the palette via `toColorScheme()`, which should keep them in the same family. If any specific M3 widget still looks "off" after the migration, the fix is to add a `cardTheme` (or equivalent) to the root `ThemeData` reading the palette — a follow-up, not part of this round.
- **Some literal-replacement sites currently use `Colors.white12` for a Divider** — this is intentional (a semi-transparent fade over whatever's below). The new `dividerSubtle` is a solid color. Visual difference: when a Divider sits over an irregular surface (e.g. inside the motion-blur playground over the preview), the new solid divider may look slightly more present. Accept the change; tune the `dividerSubtle` constant if needed via the playground.
