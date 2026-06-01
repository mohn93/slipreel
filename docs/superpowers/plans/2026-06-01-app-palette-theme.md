# App Palette Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the seed-color-driven theme with a role-based `AppPalette` ThemeExtension. Ship three named candidates (Midnight, Carbon, Obsidian), a Riverpod-backed controller that persists the user's pick, a Theme Playground screen for live preview, and a sweep that migrates every hardcoded color literal across editor / settings / recents / motion-blur screens onto the new tokens — plus the four new dividers (canvas-toolbar, canvas-inspector, body-timeline, AppBar bottom).

**Architecture:** `ThemeExtension<AppPalette>` with 10 named role fields and three `const` candidate constants. `AppPaletteStore` reads/writes a JSON sidecar at `<appSupport>/app_palette.json` (mirrors `RecordingSettingsStore`). `AppPaletteController extends StateNotifier<PaletteId>` persists on `select`. The root `MaterialApp` watches the controller and rebuilds with the palette installed via `ThemeData.extensions`. Widgets read `context.palette.<role>`.

**Tech Stack:** Dart 3 / Flutter (Material 3), Riverpod (existing), FVM 3.41.5 (`~/fvm/versions/3.41.5/bin/flutter`).

**Spec:** `docs/superpowers/specs/2026-06-01-app-palette-theme-design.md`.

---

## File Structure

**Create:**
- `packages/screen_recorder/lib/ui/theme/app_palette.dart` — `PaletteId` enum, `AppPalette` ThemeExtension, three named constants, `byId`, `toColorScheme`, `copyWith`, `lerp`.
- `packages/screen_recorder/lib/ui/theme/app_palette_context.dart` — `context.palette` extension helper.
- `packages/screen_recorder/lib/state/app_palette_store.dart` — JSON-sidecar load/save.
- `packages/screen_recorder/lib/state/app_palette_controller.dart` — `StateNotifier<PaletteId>` + provider.
- `packages/screen_recorder/lib/ui/screens/theme_playground_screen.dart` — picker + preview + token grid.
- `packages/screen_recorder/test/ui/theme/app_palette_test.dart`
- `packages/screen_recorder/test/ui/theme/app_palette_context_test.dart`
- `packages/screen_recorder/test/state/app_palette_store_test.dart`
- `packages/screen_recorder/test/state/app_palette_controller_test.dart`
- `packages/screen_recorder/test/ui/screens/theme_playground_screen_test.dart`

**Modify:**
- `packages/screen_recorder/lib/main.dart` — load store + initial palette pre-`runApp`; add provider override; watch controller in `MyApp.build`; install palette in `ThemeData`.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` — add "Appearance" section + Theme playground tile; migrate Scaffold / AppBar / card literals to tokens.
- `packages/screen_recorder/lib/ui/screens/recents_screen.dart` — migrate Scaffold / AppBar literals.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — migrate Scaffold / AppBar / gradient / accent button literals; insert 3 new dividers (above canvas toolbar, between canvas/inspector, above timeline) + AppBar bottom divider.
- `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart` — migrate Scaffold / AppBar / Divider literals; AppBar bottom divider.
- `packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart` — migrate `InspectorSectionDivider` color + card-outline border color.

---

## Tasks

### Task 1: `PaletteId` enum + `AppPalette` ThemeExtension with three named constants

**Files:**
- Create: `packages/screen_recorder/lib/ui/theme/app_palette.dart`
- Test: `packages/screen_recorder/test/ui/theme/app_palette_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/ui/theme/app_palette_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

void main() {
  group('AppPalette named constants', () {
    test('midnight / carbon / obsidian are pairwise distinct', () {
      expect(AppPalette.midnight, isNot(AppPalette.carbon));
      expect(AppPalette.midnight, isNot(AppPalette.obsidian));
      expect(AppPalette.carbon, isNot(AppPalette.obsidian));
    });

    test('every named constant has all 10 role fields non-null', () {
      for (final p in [
        AppPalette.midnight,
        AppPalette.carbon,
        AppPalette.obsidian,
      ]) {
        expect(p.appBackground, isNotNull);
        expect(p.surfaceLow, isNotNull);
        expect(p.surfaceElevated, isNotNull);
        expect(p.surfaceCard, isNotNull);
        expect(p.dividerSubtle, isNotNull);
        expect(p.dividerStrong, isNotNull);
        expect(p.accent, isNotNull);
        expect(p.accentMuted, isNotNull);
        expect(p.textPrimary, isNotNull);
        expect(p.textSecondary, isNotNull);
      }
    });
  });

  group('AppPalette.byId', () {
    test('returns the matching constant for every PaletteId', () {
      expect(AppPalette.byId(PaletteId.midnight), AppPalette.midnight);
      expect(AppPalette.byId(PaletteId.carbon), AppPalette.carbon);
      expect(AppPalette.byId(PaletteId.obsidian), AppPalette.obsidian);
    });
  });

  group('AppPalette.copyWith', () {
    test('replaces only the named field', () {
      const replacement = Color(0xFFFF0000);
      final next = AppPalette.midnight.copyWith(accent: replacement);
      expect(next.accent, replacement);
      expect(next.appBackground, AppPalette.midnight.appBackground);
      expect(next.surfaceElevated, AppPalette.midnight.surfaceElevated);
      expect(next.dividerSubtle, AppPalette.midnight.dividerSubtle);
    });
  });

  group('AppPalette.lerp', () {
    test('t=0 returns this', () {
      final result = AppPalette.midnight.lerp(AppPalette.carbon, 0.0);
      expect(result.appBackground, AppPalette.midnight.appBackground);
    });

    test('t=1 returns the other palette', () {
      final result = AppPalette.midnight.lerp(AppPalette.carbon, 1.0);
      expect(result.appBackground, AppPalette.carbon.appBackground);
    });

    test('null other returns this unchanged', () {
      final result = AppPalette.midnight.lerp(null, 0.5);
      expect(result.appBackground, AppPalette.midnight.appBackground);
    });
  });

  group('AppPalette.toColorScheme', () {
    test('maps palette roles to the matching ColorScheme slots', () {
      final scheme = AppPalette.midnight.toColorScheme();
      expect(scheme.brightness, Brightness.dark);
      expect(scheme.primary, AppPalette.midnight.accent);
      expect(scheme.background, AppPalette.midnight.appBackground);
      expect(scheme.surface, AppPalette.midnight.surfaceElevated);
      expect(scheme.outlineVariant, AppPalette.midnight.dividerSubtle);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/theme/app_palette_test.dart`
Expected: FAIL with `"Target of URI doesn't exist"`.

- [ ] **Step 3: Implement `AppPalette`**

```dart
// packages/screen_recorder/lib/ui/theme/app_palette.dart
import 'package:flutter/material.dart';

/// Selectable palettes shipped with the app. Persisted via
/// `AppPaletteStore.save(PaletteId.name)`.
enum PaletteId { midnight, carbon, obsidian }

/// Role-based palette installed on `ThemeData.extensions`. Widgets
/// read via the `context.palette.<role>` extension.
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

  final Color appBackground;
  final Color surfaceLow;
  final Color surfaceElevated;
  final Color surfaceCard;
  final Color dividerSubtle;
  final Color dividerStrong;
  final Color accent;
  final Color accentMuted;
  final Color textPrimary;
  final Color textSecondary;

  static const AppPalette midnight = AppPalette(
    appBackground: Color(0xFF0B0B10),
    surfaceLow: Color(0xFF0F0F16),
    surfaceElevated: Color(0xFF13131A),
    surfaceCard: Color(0xFF1A1A23),
    dividerSubtle: Color(0xFF22222C),
    dividerStrong: Color(0xFF33333F),
    accent: Color(0xFF7C6CFF),
    accentMuted: Color(0x2E7C6CFF), // 18% alpha
    textPrimary: Color(0xFFF2F2F5),
    textSecondary: Color(0xFF9A9AA8),
  );

  static const AppPalette carbon = AppPalette(
    appBackground: Color(0xFF121212),
    surfaceLow: Color(0xFF161616),
    surfaceElevated: Color(0xFF1B1B1B),
    surfaceCard: Color(0xFF222222),
    dividerSubtle: Color(0xFF2C2C2C),
    dividerStrong: Color(0xFF3A3A3A),
    accent: Color(0xFF8B7CFF),
    accentMuted: Color(0x2E8B7CFF),
    textPrimary: Color(0xFFEFEFEF),
    textSecondary: Color(0xFFA0A0A0),
  );

  static const AppPalette obsidian = AppPalette(
    appBackground: Color(0xFF0A0E1A),
    surfaceLow: Color(0xFF0F1626),
    surfaceElevated: Color(0xFF10162A),
    surfaceCard: Color(0xFF171F38),
    dividerSubtle: Color(0xFF1F2A48),
    dividerStrong: Color(0xFF2A3A5C),
    accent: Color(0xFF6C63FF),
    accentMuted: Color(0x2E6C63FF),
    textPrimary: Color(0xFFE8ECF5),
    textSecondary: Color(0xFF8B95B0),
  );

  static AppPalette byId(PaletteId id) => switch (id) {
        PaletteId.midnight => midnight,
        PaletteId.carbon => carbon,
        PaletteId.obsidian => obsidian,
      };

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

  @override
  AppPalette copyWith({
    Color? appBackground,
    Color? surfaceLow,
    Color? surfaceElevated,
    Color? surfaceCard,
    Color? dividerSubtle,
    Color? dividerStrong,
    Color? accent,
    Color? accentMuted,
    Color? textPrimary,
    Color? textSecondary,
  }) =>
      AppPalette(
        appBackground: appBackground ?? this.appBackground,
        surfaceLow: surfaceLow ?? this.surfaceLow,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        surfaceCard: surfaceCard ?? this.surfaceCard,
        dividerSubtle: dividerSubtle ?? this.dividerSubtle,
        dividerStrong: dividerStrong ?? this.dividerStrong,
        accent: accent ?? this.accent,
        accentMuted: accentMuted ?? this.accentMuted,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      appBackground: Color.lerp(appBackground, other.appBackground, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      dividerSubtle: Color.lerp(dividerSubtle, other.dividerSubtle, t)!,
      dividerStrong: Color.lerp(dividerStrong, other.dividerStrong, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPalette &&
      other.appBackground == appBackground &&
      other.surfaceLow == surfaceLow &&
      other.surfaceElevated == surfaceElevated &&
      other.surfaceCard == surfaceCard &&
      other.dividerSubtle == dividerSubtle &&
      other.dividerStrong == dividerStrong &&
      other.accent == accent &&
      other.accentMuted == accentMuted &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary;

  @override
  int get hashCode => Object.hash(
        appBackground,
        surfaceLow,
        surfaceElevated,
        surfaceCard,
        dividerSubtle,
        dividerStrong,
        accent,
        accentMuted,
        textPrimary,
        textSecondary,
      );
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/theme/app_palette_test.dart`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/theme/app_palette.dart \
        packages/screen_recorder/test/ui/theme/app_palette_test.dart
git commit -m "feat(app): add AppPalette ThemeExtension + Midnight/Carbon/Obsidian"
```

---

### Task 2: `context.palette` extension

**Files:**
- Create: `packages/screen_recorder/lib/ui/theme/app_palette_context.dart`
- Test: `packages/screen_recorder/test/ui/theme/app_palette_context_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/theme/app_palette_context_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

void main() {
  testWidgets('context.palette returns the palette installed on ThemeData',
      (tester) async {
    AppPalette? captured;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.carbon],
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) {
          captured = context.palette;
          return const SizedBox.shrink();
        },
      ),
    ));
    expect(captured, AppPalette.carbon);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/theme/app_palette_context_test.dart`
Expected: FAIL — extension doesn't exist.

- [ ] **Step 3: Implement the extension**

```dart
// packages/screen_recorder/lib/ui/theme/app_palette_context.dart
import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';

extension AppPaletteContext on BuildContext {
  /// The active palette installed on the nearest `ThemeData.extensions`.
  /// Throws if no `AppPalette` is registered — the app installs one at
  /// the root via `main.dart`, so missing it is always a bug.
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/theme/app_palette_context_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/theme/app_palette_context.dart \
        packages/screen_recorder/test/ui/theme/app_palette_context_test.dart
git commit -m "feat(app): add context.palette extension helper"
```

---

### Task 3: `AppPaletteStore` JSON sidecar

**Files:**
- Create: `packages/screen_recorder/lib/state/app_palette_store.dart`
- Test: `packages/screen_recorder/test/state/app_palette_store_test.dart`

The store mirrors `RecordingSettingsStore`'s pattern: a `path` field, an async `load()` returning a parsed value or null on any failure, and a `save()` that writes JSON. Errors are logged via `AppLogger.platform` and swallowed.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/state/app_palette_store_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('app_palette_store_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('AppPaletteStore', () {
    test('save then load round-trips each PaletteId', () async {
      for (final id in PaletteId.values) {
        final store = AppPaletteStore(path: p.join(tmp.path, 'p_$id.json'));
        await store.save(id);
        final loaded = await store.load();
        expect(loaded, id, reason: 'round-trip for $id');
      }
    });

    test('load returns null when the file does not exist', () async {
      final store = AppPaletteStore(path: p.join(tmp.path, 'missing.json'));
      expect(await store.load(), isNull);
    });

    test('load returns null for an unknown paletteId string', () async {
      final file = File(p.join(tmp.path, 'unknown.json'));
      await file.writeAsString('{"paletteId": "neon-pink"}');
      final store = AppPaletteStore(path: file.path);
      expect(await store.load(), isNull);
    });

    test('load returns null for invalid JSON', () async {
      final file = File(p.join(tmp.path, 'corrupt.json'));
      await file.writeAsString('not json at all');
      final store = AppPaletteStore(path: file.path);
      expect(await store.load(), isNull);
    });

    test('save creates parent directories as needed', () async {
      final store = AppPaletteStore(
        path: p.join(tmp.path, 'sub', 'dir', 'palette.json'),
      );
      await store.save(PaletteId.obsidian);
      expect(await store.load(), PaletteId.obsidian);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/app_palette_store_test.dart`
Expected: FAIL — store doesn't exist.

- [ ] **Step 3: Implement the store**

```dart
// packages/screen_recorder/lib/state/app_palette_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';

/// JSON sidecar at `<applicationSupportDirectory>/app_palette.json`
/// holding the user's last picked palette. Mirrors `RecordingSettingsStore`.
class AppPaletteStore {
  AppPaletteStore({required this.path});
  final String path;

  static Future<AppPaletteStore> resolveDefault() async {
    final dir = await getApplicationSupportDirectory();
    return AppPaletteStore(path: p.join(dir.path, 'app_palette.json'));
  }

  /// Returns the persisted palette or `null` if the file is missing,
  /// unreadable, or holds an unknown value. Never throws.
  Future<PaletteId?> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final name = json['paletteId'];
      if (name is! String) return null;
      for (final id in PaletteId.values) {
        if (id.name == name) return id;
      }
      return null;
    } catch (e, st) {
      AppLogger.platform.w('AppPaletteStore.load failed; falling back',
          error: e, stackTrace: st);
      return null;
    }
  }

  Future<void> save(PaletteId id) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode({'paletteId': id.name}));
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/app_palette_store_test.dart`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/app_palette_store.dart \
        packages/screen_recorder/test/state/app_palette_store_test.dart
git commit -m "feat(app): add AppPaletteStore JSON sidecar"
```

---

### Task 4: `AppPaletteController` + Riverpod provider

**Files:**
- Create: `packages/screen_recorder/lib/state/app_palette_controller.dart`
- Test: `packages/screen_recorder/test/state/app_palette_controller_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/state/app_palette_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/app_palette_controller.dart';
import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

/// Records save() calls without touching the filesystem.
class _RecordingStore implements AppPaletteStore {
  final List<PaletteId> saved = [];

  @override
  String get path => '<fake>';

  @override
  Future<PaletteId?> load() async => null;

  @override
  Future<void> save(PaletteId id) async {
    saved.add(id);
  }
}

void main() {
  group('AppPaletteController', () {
    test('initial state matches the constructor arg', () {
      final c = AppPaletteController(
        store: _RecordingStore(),
        initial: PaletteId.carbon,
      );
      expect(c.state, PaletteId.carbon);
    });

    test('select publishes the new id', () {
      final c = AppPaletteController(
        store: _RecordingStore(),
        initial: PaletteId.midnight,
      );
      c.select(PaletteId.obsidian);
      expect(c.state, PaletteId.obsidian);
    });

    test('select fires store.save with the chosen id', () async {
      final store = _RecordingStore();
      final c = AppPaletteController(
        store: store,
        initial: PaletteId.midnight,
      );
      c.select(PaletteId.carbon);
      // save is fire-and-forget via unawaited; the call lands on the
      // microtask queue.
      await Future<void>.delayed(Duration.zero);
      expect(store.saved, [PaletteId.carbon]);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/app_palette_controller_test.dart`
Expected: FAIL — controller doesn't exist.

- [ ] **Step 3: Implement the controller + provider**

```dart
// packages/screen_recorder/lib/state/app_palette_controller.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

/// Holds the active palette selection and persists it on every change.
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

/// Always overridden at startup in `main.dart` with a loaded store +
/// the persisted initial value. The default throws to surface missing
/// wiring early instead of silently falling back to a hard-coded palette.
final appPaletteControllerProvider =
    StateNotifierProvider<AppPaletteController, PaletteId>(
  (ref) => throw UnimplementedError(
    'Override appPaletteControllerProvider in main.dart with a loaded store',
  ),
);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/app_palette_controller_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/app_palette_controller.dart \
        packages/screen_recorder/test/state/app_palette_controller_test.dart
git commit -m "feat(app): add AppPaletteController + provider"
```

---

### Task 5: Wire the palette into `MaterialApp`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

Two changes: (a) load the store + initial value before `runApp`, register a provider override; (b) inside `MyApp.build`, watch the controller and build `ThemeData` from the palette.

- [ ] **Step 1: Add the imports**

Open `packages/screen_recorder/lib/main.dart`. Add alongside the existing state/UI imports:

```dart
import 'state/app_palette_controller.dart';
import 'state/app_palette_store.dart';
import 'ui/theme/app_palette.dart';
```

- [ ] **Step 2: Load the store + initial palette before `runApp`**

In `main()`, just BEFORE the existing `runApp(ProviderScope(...))` call (around line 145), add:

```dart
final paletteStore = await AppPaletteStore.resolveDefault();
final initialPalette = (await paletteStore.load()) ?? PaletteId.midnight;
```

- [ ] **Step 3: Register the provider override**

Inside the existing `ProviderScope(overrides: [...])`, add this entry (place it next to the other controller overrides):

```dart
appPaletteControllerProvider.overrideWith(
  (ref) => AppPaletteController(
    store: paletteStore,
    initial: initialPalette,
  ),
),
```

- [ ] **Step 4: Update `MyApp.build` to use the palette**

The class is at `class _MyAppState extends ConsumerState<MyApp>` (line 274). Inside its `build` method, find the existing `return MaterialApp(...)` (around line 432). Replace its `theme: ThemeData(...)` block with palette-driven theme:

```dart
@override
Widget build(BuildContext context) {
  final selected = ref.watch(appPaletteControllerProvider);
  final palette = AppPalette.byId(selected);

  // existing addPostFrameCallback for AppAlerts.attach stays right here

  return MaterialApp(
    navigatorKey: rootNavigatorKey,
    title: 'Slipreel',
    theme: ThemeData(
      colorScheme: palette.toColorScheme(),
      extensions: [palette],
      useMaterial3: true,
    ),
    debugShowCheckedModeBanner: false,
    navigatorObservers: [
      if (debugProbe.navigatorObserver() case final observer?) observer,
    ],
    home: widget.onboardingDone
        ? const RecordingBarScreen()
        : const OnboardingScreen(),
  );
}
```

The existing `ColorScheme.fromSeed(seedColor: const Color(0xFF6C63FF), brightness: Brightness.dark)` is REPLACED. The seed-color line goes away.

- [ ] **Step 5: Verify analyzer and tests**

Run:
```bash
~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/main.dart
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```
Expected: Analyzer passes on `main.dart` (pre-existing info-level warnings in OTHER files are fine). Tests: same baseline as before (the pre-existing `debug_probe_test` LOCAL-ONLY failure is acceptable; nothing else new should fail). The hardcoded color literals across screens still render (they don't yet read the palette — Task 9 migrates them).

- [ ] **Step 6: Manual smoke test**

Hot-restart the app via the agent-wires probe. Confirm:
- The bar still launches and looks like before.
- Opening a recording → editor opens, no crash (palette is loaded but screens haven't migrated yet — they're rendering hardcoded literals).
- Settings screen opens (still uses hardcoded `0xFF1E1E2E` / `0xFF2B2B3D` — that's fine for now).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(app): load AppPalette at startup and install on MaterialApp"
```

---

### Task 6: Theme Playground screen

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/theme_playground_screen.dart`
- Test: `packages/screen_recorder/test/ui/screens/theme_playground_screen_test.dart`

The screen is a `ConsumerWidget` that watches the controller, renders a row of three swatch tiles (tap → `controller.select(id)`), a miniature editor preview block, and a 5×2 grid of raw token swatches. Selection is live — no Apply button.

- [ ] **Step 1: Write the failing widget tests**

```dart
// packages/screen_recorder/test/ui/screens/theme_playground_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/app_palette_controller.dart';
import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/screens/theme_playground_screen.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

class _NoOpStore implements AppPaletteStore {
  @override
  String get path => '<noop>';
  @override
  Future<PaletteId?> load() async => null;
  @override
  Future<void> save(PaletteId id) async {}
}

Widget _wrap(Widget child, {PaletteId initial = PaletteId.midnight}) {
  final store = _NoOpStore();
  return ProviderScope(
    overrides: [
      appPaletteControllerProvider.overrideWith(
        (ref) => AppPaletteController(store: store, initial: initial),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: [AppPalette.byId(initial)],
        useMaterial3: true,
      ),
      home: child,
    ),
  );
}

void main() {
  testWidgets('renders three swatch tiles labeled with palette names',
      (tester) async {
    await tester.pumpWidget(_wrap(const ThemePlaygroundScreen()));
    expect(find.text('Midnight'), findsOneWidget);
    expect(find.text('Carbon'), findsOneWidget);
    expect(find.text('Obsidian'), findsOneWidget);
  });

  testWidgets('active tile shows a check icon; others do not', (tester) async {
    await tester.pumpWidget(
      _wrap(const ThemePlaygroundScreen(), initial: PaletteId.carbon),
    );
    // The active palette's tile has the check icon; non-active don't.
    final carbonTile = find.ancestor(
      of: find.text('Carbon'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: carbonTile, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    final midnightTile = find.ancestor(
      of: find.text('Midnight'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: midnightTile, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('tapping a swatch fires controller.select', (tester) async {
    await tester.pumpWidget(_wrap(const ThemePlaygroundScreen()));
    // Find the Obsidian tile and tap it.
    final obsidianTile = find.ancestor(
      of: find.text('Obsidian'),
      matching: find.byType(InkWell),
    );
    await tester.tap(obsidianTile);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ThemePlaygroundScreen)),
    );
    expect(container.read(appPaletteControllerProvider), PaletteId.obsidian);
  });

  testWidgets('token grid renders 10 hex labels', (tester) async {
    await tester.pumpWidget(_wrap(const ThemePlaygroundScreen()));
    // Each token row shows a hex string like #0B0B10. We don't pin the
    // exact strings (palette may be tuned later) — assert there are at
    // least 10 widgets matching the #XXXXXX pattern.
    final hexFinder = find.byWidgetPredicate(
      (w) => w is Text &&
          w.data != null &&
          RegExp(r'^#[0-9A-Fa-f]{6,8}$').hasMatch(w.data!),
    );
    expect(hexFinder, findsNWidgets(10));
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/screens/theme_playground_screen_test.dart`
Expected: FAIL — `ThemePlaygroundScreen` doesn't exist.

- [ ] **Step 3: Implement the screen**

```dart
// packages/screen_recorder/lib/ui/screens/theme_playground_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/app_palette_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

class ThemePlaygroundScreen extends ConsumerWidget {
  const ThemePlaygroundScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appPaletteControllerProvider);
    final palette = context.palette;

    return Scaffold(
      backgroundColor: palette.appBackground,
      appBar: AppBar(
        title: const Text('Theme playground'),
        backgroundColor: palette.surfaceElevated,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: palette.dividerSubtle),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(context, 'Palette'),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final id in PaletteId.values) ...[
                  Expanded(
                    child: _SwatchTile(
                      id: id,
                      active: id == selected,
                      onTap: () => ref
                          .read(appPaletteControllerProvider.notifier)
                          .select(id),
                    ),
                  ),
                  if (id != PaletteId.values.last) const SizedBox(width: 12),
                ],
              ],
            ),
            const SizedBox(height: 32),
            _sectionTitle(context, 'Preview'),
            const SizedBox(height: 12),
            _MiniatureEditorPreview(palette: palette),
            const SizedBox(height: 32),
            _sectionTitle(context, 'Tokens'),
            const SizedBox(height: 12),
            _TokenGrid(palette: palette),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Text(
        text,
        style: TextStyle(
          color: context.palette.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _SwatchTile extends StatelessWidget {
  const _SwatchTile({
    required this.id,
    required this.active,
    required this.onTap,
  });

  final PaletteId id;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.byId(id);
    final activePalette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: p.appBackground,
          border: Border.all(
            color: active ? activePalette.accent : activePalette.dividerSubtle,
            width: active ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            // Mini composition.
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: p.surfaceElevated,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 28,
                    decoration: BoxDecoration(
                      color: p.surfaceCard,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(height: 1, color: p.dividerSubtle),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 30,
                        height: 16,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 16,
                          decoration: BoxDecoration(
                            color: p.surfaceLow,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    _labelFor(id),
                    style: TextStyle(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: activePalette.accent,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.check,
                      size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _labelFor(PaletteId id) => switch (id) {
        PaletteId.midnight => 'Midnight',
        PaletteId.carbon => 'Carbon',
        PaletteId.obsidian => 'Obsidian',
      };
}

class _MiniatureEditorPreview extends StatelessWidget {
  const _MiniatureEditorPreview({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 320,
        decoration: BoxDecoration(
          color: palette.appBackground,
          border: Border.all(color: palette.dividerSubtle),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            // Faux AppBar.
            Container(
              height: 36,
              color: palette.surfaceElevated,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Text(
                'Editor',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(height: 1, color: palette.dividerSubtle),
            // Body: canvas (70%) | inspector (30%).
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 7,
                    child: Container(
                      color: palette.surfaceLow,
                      alignment: Alignment.center,
                      child: Container(
                        width: 80,
                        height: 50,
                        decoration: BoxDecoration(
                          color: palette.accent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                  Container(width: 1, color: palette.dividerSubtle),
                  Expanded(
                    flex: 3,
                    child: Container(
                      color: palette.surfaceElevated,
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Inspector',
                              style: TextStyle(
                                  color: palette.textPrimary,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: palette.surfaceCard,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Slider',
                                    style: TextStyle(
                                        color: palette.textSecondary,
                                        fontSize: 11)),
                                const SizedBox(height: 6),
                                Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: palette.dividerSubtle,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: palette.accentMuted,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text('chip',
                                      style: TextStyle(
                                          color: palette.accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: palette.dividerSubtle),
            // Faux timeline.
            Container(
              height: 36,
              color: palette.surfaceElevated,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 18,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenGrid extends StatelessWidget {
  const _TokenGrid({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final tokens = <(String, Color)>[
      ('appBackground', palette.appBackground),
      ('surfaceLow', palette.surfaceLow),
      ('surfaceElevated', palette.surfaceElevated),
      ('surfaceCard', palette.surfaceCard),
      ('dividerSubtle', palette.dividerSubtle),
      ('dividerStrong', palette.dividerStrong),
      ('accent', palette.accent),
      ('accentMuted', palette.accentMuted),
      ('textPrimary', palette.textPrimary),
      ('textSecondary', palette.textSecondary),
    ];

    return GridView.count(
      crossAxisCount: 5,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final (name, color) in tokens)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.surfaceCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.dividerSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.dividerSubtle),
                  ),
                ),
                const SizedBox(height: 6),
                Text(name,
                    style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
                Text(_hexOf(color),
                    style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 11,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
      ],
    );
  }

  String _hexOf(Color c) {
    final v = c.value & 0xFFFFFFFF;
    return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/screens/theme_playground_screen_test.dart`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/theme_playground_screen.dart \
        packages/screen_recorder/test/ui/screens/theme_playground_screen_test.dart
git commit -m "feat(app): add ThemePlaygroundScreen with swatch picker + token grid"
```

---

### Task 7: Settings entry to the playground

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/settings_screen.dart`

- [ ] **Step 1: Add imports**

Open `packages/screen_recorder/lib/ui/screens/settings_screen.dart`. Add:

```dart
import '../theme/app_palette_context.dart';
import 'theme_playground_screen.dart';
```

- [ ] **Step 2: Add the "Appearance" section**

Find the existing demo block (the "Alert demo" section added in the previous feature, around the `_buildAlertDemo()` callsite — search for `_buildSectionTitle('Alert demo'),`). Just BELOW the `_buildAlertDemo()` invocation (and any `SizedBox` after it), insert:

```dart
const SizedBox(height: 32),
_buildSectionTitle('Appearance'),
const SizedBox(height: 12),
Container(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  decoration: BoxDecoration(
    color: const Color(0xFF2B2B3D),
    borderRadius: BorderRadius.circular(8),
  ),
  child: ListTile(
    leading: const Icon(Icons.palette_outlined, color: Colors.white),
    title: const Text('Theme playground',
        style: TextStyle(color: Colors.white)),
    subtitle: const Text(
      'Preview and pick the app theme',
      style: TextStyle(color: Colors.white70),
    ),
    trailing: const Icon(Icons.chevron_right, color: Colors.white70),
    contentPadding: EdgeInsets.zero,
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ThemePlaygroundScreen(),
      ),
    ),
  ),
),
```

(The settings screen still uses hardcoded `Color(0xFF2B2B3D)` / `Colors.white` here. Task 9 migrates these to `context.palette.surfaceCard` / `context.palette.textPrimary`. This task keeps them hardcoded so the diff stays minimal — just the new tile.)

- [ ] **Step 3: Verify it compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/screens/settings_screen.dart`
Expected: No errors.

- [ ] **Step 4: Manual smoke test**

Hot-restart. Open Settings → scroll to "Appearance" → tap "Theme playground" → confirm the screen opens and shows the three swatch tiles + miniature editor + token grid. Tap each swatch and confirm the playground re-themes immediately.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/settings_screen.dart
git commit -m "feat(app): Settings 'Appearance' section links to Theme playground"
```

---

### Task 8: Migrate the inspector divider + inspector card border to tokens

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart`

This is the smallest migrations chunk, isolating the inspector before the screen sweep. After this task, the inspector's section dividers and card outlines reflect the active palette.

- [ ] **Step 1: Add imports**

Open `packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart`. Add:

```dart
import '../../theme/app_palette_context.dart';
```

- [ ] **Step 2: Migrate `InspectorSectionDivider`**

Find `Color(0xFF2A2A38)` in the file (around line 41 — inside `InspectorSectionDivider`). Replace with `context.palette.dividerSubtle`. The widget will need access to `BuildContext`, which it already has since it's inside a `build` method.

- [ ] **Step 3: Migrate the card outline border**

Find the second `Border.all(...)` callsite (around line 90 — inside a card outline). Replace the color literal there with `context.palette.dividerSubtle`. If that line uses a different shade (e.g. `Colors.white12`), still map to `dividerSubtle`.

- [ ] **Step 4: Verify**

Run:
```bash
~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```
Expected: Analyzer clean. Tests pass (same baseline).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart
git commit -m "refactor(app): inspector divider + card outline read from AppPalette"
```

---

### Task 9: Sweep — migrate screen literals to tokens + add new dividers

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/settings_screen.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/recents_screen.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart`

The sweep is mechanical. For each file:
1. Add `import '../theme/app_palette_context.dart';` (path-relative; adjust for the actual file location — settings/recents/playback/motion-blur all live under `ui/screens/`, so this exact path works).
2. Inside every `build`/`_build*` method that has a `BuildContext`, replace the listed literals.
3. Add the new dividers where specified.

Mapping is identical across files:
- `Color(0xFF1E1E2E)` → `context.palette.appBackground`
- `Color(0xFF2B2B3D)` → `context.palette.surfaceElevated`
- `Color(0xFF6C63FF)` → `context.palette.accent`
- `Color(0xFF181826)` → `context.palette.surfaceLow`
- `Color(0xFF0E0E18)` → `context.palette.appBackground`
- `Colors.white12` (Divider color) → `context.palette.dividerSubtle`
- Card outline border literals → `context.palette.dividerSubtle`

- [ ] **Step 1: Settings screen**

Open `packages/screen_recorder/lib/ui/screens/settings_screen.dart`. Add the import.

In the build method, replace `backgroundColor: const Color(0xFF1E1E2E)` (Scaffold, around line 81) with `backgroundColor: context.palette.appBackground`. Drop `const` since the call is no longer a constant.

Replace `backgroundColor: const Color(0xFF2B2B3D)` (AppBar, around line 84) with `backgroundColor: context.palette.surfaceElevated`.

Wrap the AppBar with a `bottom:` PreferredSize divider:
```dart
appBar: AppBar(
  title: const Text('Frame Settings'),
  backgroundColor: context.palette.surfaceElevated,
  elevation: 0,
  bottom: PreferredSize(
    preferredSize: const Size.fromHeight(1),
    child: Container(height: 1, color: context.palette.dividerSubtle),
  ),
),
```

Find the second `Color(0xFF2B2B3D)` (around line 197 — inside `_buildShortcutsCard`) and replace with `context.palette.surfaceCard`. (Cards are `surfaceCard`, not `surfaceElevated` — gives them a touch more contrast than the AppBar.)

The new "Appearance" tile (added in Task 7) still uses `Color(0xFF2B2B3D)` / `Colors.white` — migrate those too in this pass: `Color(0xFF2B2B3D)` → `context.palette.surfaceCard`; `Colors.white` text → `context.palette.textPrimary`; `Colors.white70` subtitle → `context.palette.textSecondary`.

Find the card-outline `Border.all(...)` callsites (around lines 282 and 308) and replace their color literals with `context.palette.dividerSubtle`.

- [ ] **Step 2: Recents screen**

Open `packages/screen_recorder/lib/ui/screens/recents_screen.dart`. Add the import.

Replace `backgroundColor: const Color(0xFF1E1E2E)` (Scaffold, around line 99) with `backgroundColor: context.palette.appBackground`.

Replace `backgroundColor: const Color(0xFF2B2B3D)` (AppBar, around line 103) with `backgroundColor: context.palette.surfaceElevated`. Add the `bottom: PreferredSize` divider as in Step 1.

- [ ] **Step 3: Playback screen**

Open `packages/screen_recorder/lib/ui/screens/playback_screen.dart`. Add the import.

In the main build method, around line 826 (Scaffold), replace `Color(0xFF1E1E2E)` with `context.palette.appBackground`.

Around line 829 (AppBar background), replace `Color(0xFF2B2B3D)` with `context.palette.surfaceElevated`. Add `bottom: PreferredSize` divider.

Around lines 884 and 890 (`backgroundColor`/`disabledBackgroundColor` of the export button), replace `Color(0xFF6C63FF)` with `context.palette.accent`.

Around line 937 (gradient start `Color(0xFF181826)`), replace with `context.palette.surfaceLow`. Around line 942 (gradient end `Color(0xFF0E0E18)`), replace with `context.palette.appBackground`.

**Add the three new dividers in the editor layout** (look for the editor's body in the `build` method — it's the `Column` whose preview pane was wrapped in Task 13 of the aspect-ratio plan):

- **Above the CanvasToolbar:** the `CanvasToolbar(...)` call inside the preview pane's `Column`. Just before that line, insert a `Divider(height: 1, thickness: 1, color: context.palette.dividerSubtle)`. (Use grep `grep -n "CanvasToolbar(" packages/screen_recorder/lib/ui/screens/playback_screen.dart` to locate it.)
- **Between canvas area and inspector panel:** the outer Row that hosts the preview pane on the left and `if (_isInitialized) InspectorPanel(...)` on the right. Between those two children, insert `VerticalDivider(width: 1, thickness: 1, color: context.palette.dividerSubtle)`. (Use grep `grep -n "InspectorPanel(" packages/screen_recorder/lib/ui/screens/playback_screen.dart` to locate it.)
- **Above the timeline (`_buildControls()`):** find the Column whose children include `Expanded(child: Row(...))` and then `_buildControls()`. Insert a 1px Divider between them: `Divider(height: 1, thickness: 1, color: context.palette.dividerSubtle)`.

- [ ] **Step 4: Motion blur playground**

Open `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart`. Add the import.

Replace the Scaffold/AppBar literals around lines 254/263/269/271 with `context.palette.appBackground` / `context.palette.surfaceElevated`. Add the `bottom: PreferredSize` AppBar divider.

Replace `Divider(color: Colors.white12)` (around lines 1799 and 1809) with `Divider(color: context.palette.dividerSubtle)`.

- [ ] **Step 5: Verify analyzer + tests**

Run:
```bash
~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```
Expected: Analyzer clean (no NEW errors beyond pre-existing info-level warnings). Tests green (same baseline as before; the pre-existing `debug_probe_test` LOCAL-ONLY failure is acceptable).

- [ ] **Step 6: Sanity-grep**

Run: `grep -rn "0xFF1E1E2E\|0xFF2B2B3D\|0xFF6C63FF\|0xFF181826\|0xFF0E0E18\|0xFF2A2A38" packages/screen_recorder/lib/ui/screens/ packages/screen_recorder/lib/ui/widgets/inspector/`
Expected: 0 results. Any remaining lines are sites the migration missed — go back and replace them.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/settings_screen.dart \
        packages/screen_recorder/lib/ui/screens/recents_screen.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart
git commit -m "refactor(app): sweep screens onto AppPalette + add region dividers"
```

---

### Task 10: Manual end-to-end verification

**Files:** none — verification only.

- [ ] **Step 1: Cold launch**

Stop the running app via the agent-wires probe, then re-boot it. On the very first launch after wiping `<appSupport>/app_palette.json` (if it exists), the app should default to Midnight. Open every primary screen (Recents, Editor, Settings, Motion Blur Playground if reachable) and confirm:
- All backgrounds are the very-dark Midnight tone (`#0B0B10`).
- AppBars are `#13131A` and have a 1px divider underneath.
- Editor: canvas-toolbar separator, canvas/inspector vertical separator, body/timeline horizontal separator all visible at 1px.
- Inspector section dividers and card outlines visible.

- [ ] **Step 2: Swap palettes from the playground**

Settings → Appearance → Theme playground. Tap "Carbon". Confirm:
- The playground itself re-themes immediately (its own Scaffold/AppBar/preview all reflect Carbon).
- Back out to Settings → confirm Settings is now Carbon.
- Open Editor → confirm Editor is now Carbon.

Tap "Obsidian" from the playground. Same checks.

Tap "Midnight" to return.

- [ ] **Step 3: Persistence check**

Pick "Carbon". Stop the app entirely. Re-launch. Confirm the app starts in Carbon.

Pick "Midnight" again so the final-state default is the recommended one.

- [ ] **Step 4: Hardcoded-literal regression check**

Re-run the sanity grep:
`grep -rn "0xFF1E1E2E\|0xFF2B2B3D\|0xFF6C63FF\|0xFF181826\|0xFF0E0E18\|0xFF2A2A38" packages/screen_recorder/lib/`
Expected: only matches in tests or the palette constants themselves — not in screen code.

- [ ] **Step 5: No commit**

Verification only. If anything fails, fix the offending callsite (or palette constant) and re-run from Step 1.

---

## Done

After Task 10 passes, hand off to `superpowers:finishing-a-development-branch` to merge.
