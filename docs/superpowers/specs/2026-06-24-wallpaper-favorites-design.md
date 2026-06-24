# Wallpaper Favorites — Design

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Branch (planned):** `feat/wallpaper-favorites`

## Context

The Background tab's wallpaper picker (`packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`) shows six category chips: `Favorite, macOS, Spring, Sunset, Radial, Solid`. Five render real wallpapers today; **`Favorite` is a stub** — `packages/slipreel_engine/lib/rendering/wallpaper.dart` aliases it to the macOS photo pool with the comment *"there's no real favoriting yet."*

A wallpaper's identity is a `(category, index)` pair, persisted per-project in the window-frame sidecar via `WindowFrame.wallpaperCategory` + `wallpaperIndex`.

This spec covers **Favorites only**. It is the first of three connected wallpaper-picker features the user requested; the other two are deliberately out of scope here (see *Follow-ups*).

## Goal

Let users curate a personal wallpaper library:

- **Right-click** any wallpaper tile (on any tab) → **Add to / Remove from Favorites**.
- Favorited tiles show a **filled-star badge**.
- The **Favorite** tab shows the saved wallpapers (empty-state hint when none).
- Favorites persist **across all projects** (app-global), like the snap-on-cut toggle and theme choice.
- Switching tabs (and adding/removing favorites) **animates the grid's height** so the controls below don't jump.

## Non-goals (this sub-project)

- Solid → color picker (follow-up #2).
- Replacing procedural Sunset/Radial with real photos (follow-up #3).
- Reordering favorites by drag. (Order is most-recent-first, fixed.)

## Architecture

### Data model — `WallpaperRef`

A serializable reference to a single wallpaper, encoded as an **extensible string token** so the upcoming color picker needs no migration:

- **Now:** `photo:<category>:<index>` — e.g. `photo:macOS:3`. Covers every current tab, including the procedural Sunset/Radial/Solid (they are deterministic `(category, index)` today).
- **Later (follow-up #2):** `color:<hex>` slots in alongside.

Rules:
- `WallpaperRef.encode() -> String` / `WallpaperRef.decode(String) -> WallpaperRef?`.
- `decode` returns `null` for malformed or **unknown-scheme** tokens (forward-compat: an older build silently ignores a `color:` token written by a newer one).
- Equality by value (so `isFavorite` / dedupe are simple set/list checks).
- Only the `photo:` variant is built now (YAGNI); the decoder's scheme switch is the only forward-looking part.

Lives in `packages/screen_recorder/lib/state/wallpaper_ref.dart`. No `slipreel_engine` change — a ref just carries `(category, index)` into the existing `wallpaperDecoration(category, index)`.

### Persistence — `WallpaperFavoritesStore`

Mirrors `lib/state/snap_preference_store.dart` exactly:

- `SharedPreferences`-backed, key `slipreel.wallpaper_favorites`.
- Stored as an ordered `List<String>` of encoded refs (index 0 = most recently favorited).
- `static Future<WallpaperFavoritesStore> resolveDefault()`, `List<WallpaperRef> load()` (drops tokens that fail to decode), `Future<void> save(List<WallpaperRef>)`.

### Controller — `WallpaperFavoritesController`

Mirrors `lib/state/snap_preference_controller.dart`:

- `extends StateNotifier<List<WallpaperRef>>`.
- `void toggle(WallpaperRef ref)` — if present, remove; else prepend (most-recent-first). Persists via the store on every change (`unawaited(_store.save(state))`).
- `bool isFavorite(WallpaperRef ref)`.
- `final wallpaperFavoritesProvider = StateNotifierProvider<…, List<WallpaperRef>>` whose default throws `UnimplementedError` (forces the main.dart override, same as snap).

### Bootstrap — `main.dart`

Two-line addition mirroring snap (lines ~158–159 + the `ProviderScope` override):

```dart
final wallpaperFavoritesStore = await WallpaperFavoritesStore.resolveDefault();
final initialFavorites = wallpaperFavoritesStore.load();
// …
wallpaperFavoritesProvider.overrideWith((ref) => WallpaperFavoritesController(
      store: wallpaperFavoritesStore, initial: initialFavorites)),
```

## Interaction (shared tile — works on every tab)

Favoriting lives on the shared `_WallpaperThumb`, used by every tab's grid, so "favoriting works on all tabs" falls out for free. `_WallpaperThumb` stays presentational: it gains `bool isFavorite` and `VoidCallback onToggleFavorite`; the grid (a `ConsumerState` build) watches `wallpaperFavoritesProvider` and computes `isFavorite` per tile.

- **Left-click** — apply the wallpaper (unchanged).
- **Right-click** — `GestureDetector(onSecondaryTapDown:)` → `showMenu` (same pattern as the playback screen's view menu) anchored at the tap's `globalPosition`. One item, state-dependent:
  - not favorited → **Add to Favorites** (`Icons.star_border`)
  - favorited → **Remove from Favorites** (`Icons.star`)
  - on select → `onToggleFavorite()`.
- **Star badge** — when `isFavorite`, a small filled star (`Icons.star`, ~14px, white) on a subtle dark circular scrim in the tile's top-right corner, so it reads on any wallpaper. Overlaid via `Stack`/`Positioned`; does not conflict with the existing 2px accent selection border.

## The Favorite tab

When the `Favorite` chip is selected, the grid region renders from `wallpaperFavoritesProvider` instead of the 16 generated tiles:

- **Has favorites:** a grid of the saved refs (most-recent-first), each resolved via `wallpaperDecoration(ref.category, ref.index)`. Same `GridView.count(crossAxisCount: 7)` layout as the category grids.
- **Empty:** an `InspectorPlaceholder(icon: Icons.star_border, title: "No favorites yet", body: "Right-click any wallpaper and choose Add to Favorites to save it here.")`.
- **Apply:** clicking a saved tile applies its underlying `(category, index)` to the frame via the existing `_updateWallpaper(category:, index:)`.
- **Sticky chip:** applying a favorite sets `frame.wallpaperCategory` to the underlying category (e.g. `macOS`), which today's auto-sync (`background_tab.dart:79–82`) would use to bounce the chip out of Favorite. Fix: the auto-sync **skips while `_selectedCategory == 'Favorite'`** — the Favorite chip is a sticky view. Selecting any other chip resumes normal follow behavior.
- **Selected ring:** inside Favorite, the accent ring highlights the saved tile whose `(category, index)` equals the frame's current `(wallpaperCategory, wallpaperIndex)`, if any.
- **Pick-random button:** stays visible on all tabs (keeps the layout above the grid stable so only the grid animates). On Favorite it picks a random saved favorite and is disabled when there are none. *(Low-confidence detail — easy to change to "hidden on Favorite".)*

## Animated resize

The grid's height differs by tab (16 tiles = 3 rows, a 3-favorite grid = 1 row, empty state = placeholder height) and changes live as favorites are added/removed. Wrap **only the swappable grid region** (the grid / empty-state) in:

```dart
AnimatedSize(
  duration: const Duration(milliseconds: 240),
  curve: Curves.easeOutCubic,      // match the app's motion language
  alignment: Alignment.topCenter,  // grow/shrink downward; content below slides
  child: <grid or empty-state>,
)
```

- The `Pick-random` button and chips sit **above** the animated region and don't move, so only the grid's height tweens and the divider + sliders below slide smoothly.
- `AnimatedSize` manages its own ticker (no explicit vsync needed) and clips the child to the animating box (default `Clip.hardEdge`), giving a clean top-down reveal/collapse as content swaps. A content cross-fade (`AnimatedSwitcher`) is **optional polish, not in v1**.
- Final duration/curve to be tuned by eye against existing inspector motion (e.g. the rail indicator's `easeOutQuint` 280ms).

## Testing (TDD)

- **`WallpaperRef`**: encode/decode round-trip; `decode` returns `null` for malformed and unknown-scheme tokens; value equality.
- **`WallpaperFavoritesController`**: `toggle` adds (prepended), removes, and dedupes; `isFavorite`; order is most-recent-first.
- **`WallpaperFavoritesStore`**: load/save round-trip with `SharedPreferences.setMockInitialValues`; malformed tokens dropped on load.
- **Widget (`background_tab`)**:
  - right-click a tile → menu shows the correct label for its state; selecting it toggles and the star badge appears/disappears.
  - Favorite tab renders saved tiles; shows the empty-state placeholder when none.
  - applying a favorite keeps the `Favorite` chip selected (sticky) and rings the matching tile.
  - `AnimatedSize` is present wrapping the grid region (structural guard against regressions).

## Files

**New** (`packages/screen_recorder/lib/state/`):
- `wallpaper_ref.dart`
- `wallpaper_favorites_store.dart`
- `wallpaper_favorites_controller.dart`

**Edited:**
- `packages/screen_recorder/lib/main.dart` — resolve store + initial, override provider.
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart` — Favorite-tab grid + empty state + apply + sticky chip + ring; right-click menu, star badge, and `isFavorite`/`onToggleFavorite` on `_WallpaperThumb`; `AnimatedSize` around the grid region.

**Tests** under `packages/screen_recorder/test/`.

## Follow-ups (separate specs, already sequenced)

2. **Solid → color picker** — adds the `color:<hex>` `WallpaperRef` variant + a custom color in `WindowFrame`.
3. **Real photo sets for Sunset/Radial** — Unsplash-licensed assets like macOS/Spring; decide what "Radial" becomes as a photo theme; migrate orphaned `(category, index)` refs if a category is renamed.
