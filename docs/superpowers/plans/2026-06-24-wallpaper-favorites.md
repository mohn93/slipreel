# Wallpaper Favorites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users build a personal, app-global wallpaper favorites library — right-click any tile to favorite it, see a star badge, and browse saved wallpapers in the Favorite tab — with the grid resizing smoothly between tabs.

**Architecture:** A `SharedPreferences`-backed store + Riverpod `StateNotifier` (mirroring the existing snap-on-cut preference) holds an ordered list of `WallpaperRef` tokens. The Background tab's shared `_WallpaperThumb` gains a right-click menu + star badge (so favoriting works on every tab), and the Favorite tab renders the saved refs (or an empty state). The swappable grid region is wrapped in `AnimatedSize` so height changes animate.

**Tech Stack:** Flutter, `flutter_riverpod` (`StateNotifierProvider`), `shared_preferences`, `flutter_test`.

## Global Constraints

- **No `slipreel_engine` changes.** A `WallpaperRef` only carries `(category, index)` into the existing `wallpaperDecoration(category, index)`.
- **Do NOT run `dart format`** — the pinned formatter is tall-style but committed code isn't, so it reflows ~50+ unrelated lines. Match surrounding style by hand. Verify with `fvm flutter analyze` + `fvm flutter test`.
- **Run tests/analyze with `fvm`** from `packages/screen_recorder/` (FVM 3.41.5): `fvm flutter test <path>`, `fvm flutter analyze <paths>`.
- **App-global persistence key:** `slipreel.wallpaper_favorites` (a `List<String>` of encoded refs).
- **Favorites order:** most-recently-favorited first (index 0 = newest).
- **Mirror existing patterns:** `lib/state/snap_preference_store.dart` and `lib/state/snap_preference_controller.dart` for the store/controller; the `showMenu`/`PopupMenuItem` block in `lib/ui/screens/playback_screen.dart` (~line 1151) for the right-click menu.
- All new state files live in `packages/screen_recorder/lib/state/`; tests under `packages/screen_recorder/test/`.

## File Structure

**Create:**
- `lib/state/wallpaper_ref.dart` — `WallpaperRef` value type (encode/decode/equality).
- `lib/state/wallpaper_favorites_store.dart` — SharedPreferences persistence.
- `lib/state/wallpaper_favorites_controller.dart` — `StateNotifier` + `wallpaperFavoritesProvider`.
- `test/state/wallpaper_ref_test.dart`
- `test/state/wallpaper_favorites_store_test.dart`
- `test/state/wallpaper_favorites_controller_test.dart`
- `test/ui/widgets/inspector/background_tab_favorites_test.dart`

**Modify:**
- `lib/main.dart` — resolve the store + initial value, override the provider.
- `lib/ui/widgets/inspector/tabs/background_tab.dart` — right-click menu + star badge on `_WallpaperThumb`; Favorite-tab grid + empty state + apply + sticky chip + ring; `AnimatedSize` around the grid region.

---

### Task 1: `WallpaperRef` model

**Files:**
- Create: `packages/screen_recorder/lib/state/wallpaper_ref.dart`
- Test: `packages/screen_recorder/test/state/wallpaper_ref_test.dart`

**Interfaces:**
- Produces: `class WallpaperRef` with `const WallpaperRef.photo(String category, int index)`, fields `String category` / `int index`, `String encode()`, `static WallpaperRef? decode(String token)`, value `==`/`hashCode`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/wallpaper_ref_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';

void main() {
  test('encode/decode round-trips a photo ref', () {
    const ref = WallpaperRef.photo('macOS', 3);
    expect(ref.encode(), 'photo:macOS:3');
    expect(WallpaperRef.decode('photo:macOS:3'), ref);
  });

  test('decode returns null for malformed tokens', () {
    expect(WallpaperRef.decode('photo:macOS'), isNull);
    expect(WallpaperRef.decode('photo:macOS:x'), isNull);
    expect(WallpaperRef.decode(''), isNull);
  });

  test('decode returns null for unknown scheme (forward-compat)', () {
    expect(WallpaperRef.decode('color:FF8800'), isNull);
  });

  test('value equality', () {
    expect(const WallpaperRef.photo('Spring', 1),
        const WallpaperRef.photo('Spring', 1));
    expect(const WallpaperRef.photo('Spring', 1),
        isNot(const WallpaperRef.photo('Spring', 2)));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_ref_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'screen_recorder' ... wallpaper_ref.dart` / `WallpaperRef` undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/state/wallpaper_ref.dart

/// A serializable reference to a single wallpaper in the picker.
///
/// Encoded as an extensible string token so new wallpaper kinds (e.g. a
/// custom solid color, coming with the color-picker feature) can be added
/// without migrating persisted favorites:
///   - `photo:<category>:<index>` — a bundled or procedural wallpaper.
class WallpaperRef {
  const WallpaperRef.photo(this.category, this.index);

  final String category;
  final int index;

  /// Encode to a persistence token.
  String encode() => 'photo:$category:$index';

  /// Decode a token. Returns null for malformed or unknown-scheme tokens,
  /// so an older build silently ignores a token a newer build wrote.
  static WallpaperRef? decode(String token) {
    final parts = token.split(':');
    if (parts.length != 3 || parts[0] != 'photo' || parts[1].isEmpty) {
      return null;
    }
    final index = int.tryParse(parts[2]);
    if (index == null) return null;
    return WallpaperRef.photo(parts[1], index);
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperRef &&
      other.category == category &&
      other.index == index;

  @override
  int get hashCode => Object.hash(category, index);

  @override
  String toString() => 'WallpaperRef(${encode()})';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_ref_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/wallpaper_ref.dart \
        packages/screen_recorder/test/state/wallpaper_ref_test.dart
git commit -m "feat(wallpaper): add WallpaperRef favorites token model"
```

---

### Task 2: `WallpaperFavoritesStore`

**Files:**
- Create: `packages/screen_recorder/lib/state/wallpaper_favorites_store.dart`
- Test: `packages/screen_recorder/test/state/wallpaper_favorites_store_test.dart`

**Interfaces:**
- Consumes: `WallpaperRef` (Task 1).
- Produces: `class WallpaperFavoritesStore` with `static Future<WallpaperFavoritesStore> resolveDefault()`, `List<WallpaperRef> load()`, `Future<void> save(List<WallpaperRef>)`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/wallpaper_favorites_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/state/wallpaper_favorites_store.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';

void main() {
  test('save then load round-trips favorites in order', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await WallpaperFavoritesStore.resolveDefault();
    final favs = [
      const WallpaperRef.photo('macOS', 2),
      const WallpaperRef.photo('Sunset', 5),
    ];
    await store.save(favs);
    expect(store.load(), favs);
  });

  test('load drops malformed/unknown tokens', () async {
    SharedPreferences.setMockInitialValues({
      'slipreel.wallpaper_favorites': ['photo:macOS:1', 'garbage', 'color:FFF'],
    });
    final store = await WallpaperFavoritesStore.resolveDefault();
    expect(store.load(), [const WallpaperRef.photo('macOS', 1)]);
  });

  test('load defaults to empty', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await WallpaperFavoritesStore.resolveDefault();
    expect(store.load(), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_favorites_store_test.dart`
Expected: FAIL — `WallpaperFavoritesStore` undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/state/wallpaper_favorites_store.dart
import 'package:shared_preferences/shared_preferences.dart';

import 'package:screen_recorder/state/wallpaper_ref.dart';

/// SharedPreferences-backed persistence for the wallpaper favorites
/// library. Per-user (not per-project) — favorites persist across
/// recordings. Mirrors [SnapPreferenceStore].
class WallpaperFavoritesStore {
  WallpaperFavoritesStore(this._prefs);

  static const _key = 'slipreel.wallpaper_favorites';

  final SharedPreferences _prefs;

  static Future<WallpaperFavoritesStore> resolveDefault() async {
    final prefs = await SharedPreferences.getInstance();
    return WallpaperFavoritesStore(prefs);
  }

  /// Loads saved favorites, dropping any tokens that fail to decode.
  List<WallpaperRef> load() {
    final tokens = _prefs.getStringList(_key) ?? const [];
    return tokens
        .map(WallpaperRef.decode)
        .whereType<WallpaperRef>()
        .toList();
  }

  Future<void> save(List<WallpaperRef> favorites) => _prefs.setStringList(
        _key,
        favorites.map((r) => r.encode()).toList(),
      );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_favorites_store_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/wallpaper_favorites_store.dart \
        packages/screen_recorder/test/state/wallpaper_favorites_store_test.dart
git commit -m "feat(wallpaper): add SharedPreferences favorites store"
```

---

### Task 3: `WallpaperFavoritesController` + provider

**Files:**
- Create: `packages/screen_recorder/lib/state/wallpaper_favorites_controller.dart`
- Test: `packages/screen_recorder/test/state/wallpaper_favorites_controller_test.dart`

**Interfaces:**
- Consumes: `WallpaperFavoritesStore` (Task 2), `WallpaperRef` (Task 1).
- Produces: `class WallpaperFavoritesController extends StateNotifier<List<WallpaperRef>>` with ctor `({required WallpaperFavoritesStore store, required List<WallpaperRef> initial})`, `bool isFavorite(WallpaperRef)`, `void toggle(WallpaperRef)`; and `final wallpaperFavoritesProvider = StateNotifierProvider<WallpaperFavoritesController, List<WallpaperRef>>`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/wallpaper_favorites_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/state/wallpaper_favorites_controller.dart';
import 'package:screen_recorder/state/wallpaper_favorites_store.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';

void main() {
  late WallpaperFavoritesController controller;
  late WallpaperFavoritesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await WallpaperFavoritesStore.resolveDefault();
    controller = WallpaperFavoritesController(store: store, initial: const []);
  });

  test('toggle adds most-recent-first', () {
    controller.toggle(const WallpaperRef.photo('macOS', 1));
    controller.toggle(const WallpaperRef.photo('Sunset', 2));
    expect(controller.state, const [
      WallpaperRef.photo('Sunset', 2),
      WallpaperRef.photo('macOS', 1),
    ]);
  });

  test('toggle removes an existing favorite', () {
    const ref = WallpaperRef.photo('macOS', 1);
    controller.toggle(ref);
    controller.toggle(ref);
    expect(controller.state, isEmpty);
    expect(controller.isFavorite(ref), isFalse);
  });

  test('isFavorite reflects membership', () {
    const ref = WallpaperRef.photo('Spring', 0);
    expect(controller.isFavorite(ref), isFalse);
    controller.toggle(ref);
    expect(controller.isFavorite(ref), isTrue);
  });

  test('toggle persists to the store', () async {
    controller.toggle(const WallpaperRef.photo('macOS', 4));
    await Future<void>.delayed(Duration.zero); // let the unawaited save run
    expect(store.load(), const [WallpaperRef.photo('macOS', 4)]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_favorites_controller_test.dart`
Expected: FAIL — `WallpaperFavoritesController` undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/state/wallpaper_favorites_controller.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/wallpaper_favorites_store.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';

/// Holds the wallpaper favorites library (most-recent-first) and persists
/// it on every change. Mirrors [SnapPreferenceController].
class WallpaperFavoritesController extends StateNotifier<List<WallpaperRef>> {
  WallpaperFavoritesController({
    required WallpaperFavoritesStore store,
    required List<WallpaperRef> initial,
  })  : _store = store,
        super(initial);

  final WallpaperFavoritesStore _store;

  bool isFavorite(WallpaperRef ref) => state.contains(ref);

  /// Adds [ref] (most-recent-first) if absent, removes it if present.
  void toggle(WallpaperRef ref) {
    if (state.contains(ref)) {
      state = state.where((r) => r != ref).toList();
    } else {
      state = [ref, ...state];
    }
    unawaited(_store.save(state));
  }
}

/// Always overridden in main.dart with a loaded store + persisted initial.
/// The default throws to surface missing wiring early.
final wallpaperFavoritesProvider =
    StateNotifierProvider<WallpaperFavoritesController, List<WallpaperRef>>(
  (ref) => throw UnimplementedError(
    'Override wallpaperFavoritesProvider in main.dart with a loaded store',
  ),
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_favorites_controller_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/wallpaper_favorites_controller.dart \
        packages/screen_recorder/test/state/wallpaper_favorites_controller_test.dart
git commit -m "feat(wallpaper): add favorites StateNotifier + provider"
```

---

### Task 4: Bootstrap the provider in `main.dart`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart` (imports ~line 35; resolve ~line 159; override ~line 206)

**Interfaces:**
- Consumes: `WallpaperFavoritesStore`, `WallpaperFavoritesController`, `wallpaperFavoritesProvider` (Tasks 2–3).

> No unit test — this is bootstrap wiring (widget tests override the provider directly). The gate is a clean `flutter analyze` and the unchanged existing suite.

- [ ] **Step 1: Add the imports**

After `import 'state/snap_preference_controller.dart';` (line 35), add:

```dart
import 'state/wallpaper_favorites_store.dart';
import 'state/wallpaper_favorites_controller.dart';
```

- [ ] **Step 2: Resolve the store + initial value**

After the snap lines (`final snapEnabledInitial = snapPreferenceStore.load();`, line 159), add:

```dart
  final wallpaperFavoritesStore =
      await WallpaperFavoritesStore.resolveDefault();
  final initialFavorites = wallpaperFavoritesStore.load();
```

- [ ] **Step 3: Override the provider**

Inside the `ProviderScope(overrides: [ ... ])` list, after the `snapPreferenceProvider.overrideWith(...)` block (ends line 206), add:

```dart
      wallpaperFavoritesProvider.overrideWith(
        (ref) => WallpaperFavoritesController(
          store: wallpaperFavoritesStore,
          initial: initialFavorites,
        ),
      ),
```

- [ ] **Step 4: Verify it analyzes clean and the suite still passes**

Run: `cd packages/screen_recorder && fvm flutter analyze lib/main.dart`
Expected: `No issues found!`

Run: `cd packages/screen_recorder && fvm flutter test test/state/`
Expected: PASS (all state tests green).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(wallpaper): wire favorites provider in app bootstrap"
```

---

### Task 5: Right-click menu + star badge on the shared tile

Adds favoriting to the shared `_WallpaperThumb`, so it works on every category tab. The grid watches `wallpaperFavoritesProvider` and passes per-tile state.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart`

**Interfaces:**
- Consumes: `wallpaperFavoritesProvider`, `WallpaperRef`.
- Produces: `_WallpaperThumb` now takes `Key? key, BoxDecoration decoration, bool isSelected, bool isFavorite, VoidCallback onTap, VoidCallback onToggleFavorite`; tiles are keyed `ValueKey(ref.encode())`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/wallpaper_favorites_controller.dart';
import 'package:screen_recorder/state/wallpaper_favorites_store.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/background_tab.dart';

Future<Widget> host({required List<WallpaperRef> initialFavorites}) async {
  SharedPreferences.setMockInitialValues({});
  final store = await WallpaperFavoritesStore.resolveDefault();
  return ProviderScope(
    overrides: [
      editorProjectControllerProvider
          .overrideWith((ref) => EditorProjectController()),
      wallpaperFavoritesProvider.overrideWith(
        (ref) => WallpaperFavoritesController(
          store: store,
          initial: initialFavorites,
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: BackgroundTab())),
  );
}

void main() {
  testWidgets('right-click a tile favorites it and shows a star badge',
      (tester) async {
    await tester.pumpWidget(await host(initialFavorites: const []));
    await tester.pumpAndSettle();

    // Default tab is macOS; no badge yet.
    expect(find.byIcon(Icons.star), findsNothing);

    // Right-click the first tile → menu appears.
    await tester.tap(
      find.byKey(const ValueKey('photo:macOS:0')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Add to Favorites'), findsOneWidget);

    // Choose it → tile shows a filled-star badge.
    await tester.tap(find.text('Add to Favorites'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.star), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: FAIL — no tile with key `photo:macOS:0` (the thumb isn't keyed / has no menu yet).

- [ ] **Step 3: Add the imports**

In `background_tab.dart`, after the existing `import 'package:slipreel_engine/rendering/wallpaper.dart';` line add:

```dart
import 'package:screen_recorder/state/wallpaper_favorites_controller.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';
```

(`onSecondaryTapDown` comes from `GestureDetector` in `material.dart` — no extra `gestures.dart` import is needed in this file. `kSecondaryButton` is only used in the test file, which imports `package:flutter/gestures.dart`.)

- [ ] **Step 4: Watch favorites in `build` and pass to the grid**

In `build`, after `final frame = ref.watch(editorProjectControllerProvider).windowFrame;` add:

```dart
    final favorites = ref.watch(wallpaperFavoritesProvider);
```

Change the grid call in the `children:` list from `_wallpaperGrid(selectedCategory, selectedIndex)` to:

```dart
        _wallpaperGrid(selectedCategory, selectedIndex, favorites),
```

- [ ] **Step 5: Update `_wallpaperGrid` to build favorite-aware, keyed tiles**

Replace the whole `_wallpaperGrid` method with the grid + a `_categoryThumb` helper
(the helper avoids declaring a local inside the collection-`for`):

```dart
  Widget _wallpaperGrid(
    String category,
    int selectedIndex,
    List<WallpaperRef> favorites,
  ) {
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1,
      children: [
        for (int i = 0; i < kWallpapersPerCategory; i++)
          _categoryThumb(category, i, selectedIndex, favorites),
      ],
    );
  }

  Widget _categoryThumb(
    String category,
    int i,
    int selectedIndex,
    List<WallpaperRef> favorites,
  ) {
    final wref = WallpaperRef.photo(category, i);
    return _WallpaperThumb(
      key: ValueKey(wref.encode()),
      decoration: wallpaperDecoration(category, i),
      isSelected: i == selectedIndex,
      isFavorite: favorites.contains(wref),
      onTap: () => _updateWallpaper(category: category, index: i),
      onToggleFavorite: () =>
          ref.read(wallpaperFavoritesProvider.notifier).toggle(wref),
    );
  }
```

- [ ] **Step 6: Replace `_WallpaperThumb` with the menu + badge version**

Replace the entire `_WallpaperThumb` class with:

```dart
class _WallpaperThumb extends StatelessWidget {
  const _WallpaperThumb({
    super.key,
    required this.decoration,
    required this.isSelected,
    required this.isFavorite,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final BoxDecoration decoration;
  final bool isSelected;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  Future<void> _showFavoriteMenu(BuildContext context, Offset globalPos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      color: kInspectorPanel,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: kInspectorBorder),
      ),
      items: [
        PopupMenuItem<bool>(
          value: true,
          height: 36,
          child: Row(
            children: [
              Icon(isFavorite ? Icons.star : Icons.star_border,
                  size: 16, color: Colors.white),
              const SizedBox(width: 10),
              Text(
                isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
    if (selected == true) onToggleFavorite();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (d) => _showFavoriteMenu(context, d.globalPosition),
      child: SpringHoverButton(
        onTap: onTap,
        borderRadius: 8,
        child: Stack(
          children: [
            Container(
              decoration: decoration.copyWith(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? kInspectorAccent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            if (isFavorite)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.star, size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 7: Run test + analyze**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: PASS (1 test).

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/tabs/background_tab.dart`
Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart \
        packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart
git commit -m "feat(wallpaper): right-click favorite menu + star badge on tiles"
```

---

### Task 6: Make the Favorite tab real (grid / empty state / apply / sticky chip / ring)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart` (add cases)

**Interfaces:**
- Consumes: everything from Task 5.
- Produces: `_gridRegion(String category, WindowFrame frame, List<WallpaperRef> favorites)`, `_favoritesGrid(...)`, `_favoritesEmptyState()`.

- [ ] **Step 1: Write the failing tests (append to the existing test file)**

```dart
  testWidgets('Favorite tab shows the empty state when there are none',
      (tester) async {
    await tester.pumpWidget(await host(initialFavorites: const []));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();
    expect(find.text('No favorites yet'), findsOneWidget);
  });

  testWidgets('Favorite tab renders saved wallpapers, applies, stays sticky',
      (tester) async {
    await tester.pumpWidget(
      await host(initialFavorites: const [WallpaperRef.photo('Sunset', 4)]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('photo:Sunset:4'));
    expect(tile, findsOneWidget);

    // Apply it.
    await tester.tap(tile);
    await tester.pumpAndSettle();

    final editor = ProviderScope.containerOf(
      tester.element(find.byType(BackgroundTab)),
    ).read(editorProjectControllerProvider.notifier);
    expect(editor.current.windowFrame.wallpaperCategory, 'Sunset');
    expect(editor.current.windowFrame.wallpaperIndex, 4);

    // Sticky: still on the Favorite tab (the favorite is still shown).
    expect(find.byKey(const ValueKey('photo:Sunset:4')), findsOneWidget);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: FAIL — the Favorite tab still renders the macOS-aliased grid (no `No favorites yet`; no `photo:Sunset:4` tile).

- [ ] **Step 3: Make the category auto-sync sticky on Favorite**

In `build`, change the live-category sync block to not follow the frame while the user is on the Favorite tab:

```dart
    final liveCategory = frame.wallpaperCategory;
    if (liveCategory != null &&
        liveCategory != _selectedCategory &&
        _selectedCategory != 'Favorite') {
      _selectedCategory = liveCategory;
    }
```

- [ ] **Step 4: Route the grid through `_gridRegion`**

Remove the now-unused top-level `selectedIndex` computation (the `final selectedIndex = ...` lines). Change the grid entry in the `children:` list from `_wallpaperGrid(selectedCategory, selectedIndex, favorites)` to:

```dart
        _gridRegion(selectedCategory, frame, favorites),
```

Also pass `favorites` to the random button so it can pick from the saved set on the Favorite tab — change `_randomButton(selectedCategory)` to:

```dart
        _randomButton(selectedCategory, favorites),
```

- [ ] **Step 5: Add `_gridRegion`, `_favoritesGrid`, `_favoritesEmptyState`**

Add these methods to `_BackgroundTabState` (place `_gridRegion` just above `_wallpaperGrid`):

```dart
  Widget _gridRegion(
    String category,
    WindowFrame frame,
    List<WallpaperRef> favorites,
  ) {
    if (category == 'Favorite') {
      return favorites.isEmpty
          ? _favoritesEmptyState()
          : _favoritesGrid(frame, favorites);
    }
    final selectedIndex =
        frame.wallpaperCategory == category ? frame.wallpaperIndex : -1;
    return _wallpaperGrid(category, selectedIndex, favorites);
  }

  Widget _favoritesGrid(WindowFrame frame, List<WallpaperRef> favorites) {
    final notifier = ref.read(wallpaperFavoritesProvider.notifier);
    final current = (frame.wallpaperCategory != null)
        ? WallpaperRef.photo(frame.wallpaperCategory!, frame.wallpaperIndex)
        : null;
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1,
      children: [
        for (final wref in favorites)
          _WallpaperThumb(
            key: ValueKey(wref.encode()),
            decoration: wallpaperDecoration(wref.category, wref.index),
            isSelected: wref == current,
            isFavorite: true,
            onTap: () =>
                _updateWallpaper(category: wref.category, index: wref.index),
            onToggleFavorite: () => notifier.toggle(wref),
          ),
      ],
    );
  }

  Widget _favoritesEmptyState() {
    return const InspectorPlaceholder(
      icon: Icons.star_border,
      title: 'No favorites yet',
      body: 'Right-click any wallpaper and choose Add to Favorites '
          'to save it here.',
    );
  }
```

Also update `_randomButton` to take `favorites` and, on the Favorite tab, pick a
random saved favorite (no-op when empty) — change its signature and `onTap`:

```dart
  Widget _randomButton(String category, List<WallpaperRef> favorites) {
    return SpringHoverButton(
      onTap: () {
        if (category == 'Favorite') {
          if (favorites.isEmpty) return; // nothing to pick from yet
          final pick = favorites[Random().nextInt(favorites.length)];
          _updateWallpaper(category: pick.category, index: pick.index);
        } else {
          _updateWallpaper(
            category: category,
            index: Random().nextInt(kWallpapersPerCategory),
          );
        }
      },
      // ... rest of the existing SpringHoverButton child (Container/Row) is
      // unchanged.
```

Leave the button's `Container`/`Row` child exactly as it is today; only the
signature and `onTap` change.

- [ ] **Step 6: Run tests + analyze**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: PASS (3 tests).

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/tabs/background_tab.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart \
        packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart
git commit -m "feat(wallpaper): real Favorite tab (grid, empty state, apply, sticky)"
```

---

### Task 7: Animate the grid resize

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart` (add a case)

**Interfaces:**
- Consumes: `_gridRegion` (Task 6).

- [ ] **Step 1: Write the failing test (append)**

```dart
  testWidgets('grid region is wrapped in AnimatedSize and tab-switch is smooth',
      (tester) async {
    await tester.pumpWidget(
      await host(initialFavorites: const [WallpaperRef.photo('Sunset', 4)]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsOneWidget);

    // Switching to a different-height tab must not throw.
    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: FAIL — `find.byType(AnimatedSize)` returns nothing.

- [ ] **Step 3: Wrap `_gridRegion`'s result in `AnimatedSize`**

Refactor `_gridRegion` so its content is wrapped once:

```dart
  Widget _gridRegion(
    String category,
    WindowFrame frame,
    List<WallpaperRef> favorites,
  ) {
    final Widget content;
    if (category == 'Favorite') {
      content = favorites.isEmpty
          ? _favoritesEmptyState()
          : _favoritesGrid(frame, favorites);
    } else {
      final selectedIndex =
          frame.wallpaperCategory == category ? frame.wallpaperIndex : -1;
      content = _wallpaperGrid(category, selectedIndex, favorites);
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: content,
    );
  }
```

- [ ] **Step 4: Run test + analyze**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: PASS (4 tests).

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/tabs/background_tab.dart`
Expected: `No issues found!`

- [ ] **Step 5: Run the full inspector + state suites (regression gate)**

Run: `cd packages/screen_recorder && fvm flutter test test/state/ test/ui/widgets/inspector/ test/ui/inspector_tab_test.dart`
Expected: PASS (all green).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart \
        packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart
git commit -m "feat(wallpaper): animate grid resize across tab switches"
```

---

## Manual verification (after all tasks)

Build + launch the macOS app (note: `flutter run -d macos` fails on the arm64 destination under this setup — build via `xcodebuild` against the x86_64 destination, then `open` the bundle), open a recording → editor → inspector → Background tab. Verify: right-click a tile shows the menu; favoriting adds a star badge; the Favorite tab lists saved wallpapers (and shows the empty state when cleared); applying a favorite keeps you on the Favorite tab; switching tabs animates the controls below instead of jumping.

## Follow-ups (separate specs, already sequenced)

2. **Solid → color picker** — adds a `color:<hex>` `WallpaperRef` variant + a custom color on `WindowFrame`.
3. **Real photo sets for Sunset/Radial** — Unsplash-licensed assets; decide what "Radial" becomes; migrate orphaned refs if a category is renamed.
