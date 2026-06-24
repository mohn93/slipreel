# Solid → Color Picker — Design

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Branch:** `feat/wallpaper-solid-color-picker` (off `main` @ a3fc6f8f, which has the merged favorites)

## Context

The Background tab's wallpaper picker has a **Solid** category that currently shows 16 *procedurally generated* solid tiles (`_solid(Random)` in `packages/slipreel_engine/lib/rendering/wallpaper.dart`, seeded by index). The user wants a real **color picker** — pick any exact color — instead of the 16 random presets.

This is sub-project #2 of the 3-PR wallpaper-picker overhaul (after [favorites, merged PR #26]). It also lands the **`color:` `WallpaperRef` variant** the favorites work deliberately left as a forward-compatible slot, so custom colors become favoritable.

## Goal

- The **Solid** tab becomes a real color picker: a saturation/brightness square + hue slider + hex input + a row of curated preset swatches.
- Picking a color applies it live to the canvas and persists per-project.
- Custom colors are **favoritable** (a `color:` ref) and appear in the Favorite tab.
- Old projects with index-based procedural solids still render (backward compatible).

## Non-goals

- No "recent colors" row — Favorites covers deliberately saving colors. (Possible later.)
- No alpha/opacity — solid backgrounds are opaque, RGB only.
- Not reusing the picker for caption/border colors yet (build it reusable; wire elsewhere later — YAGNI).
- Sub-project #3 (real photos for Sunset/Radial) is out of scope.

## Architecture

### Data model

**`WindowFrame.solidColor`** — new `Color?` field, serialized exactly like the existing `backgroundColor`:
- `toJson`: `'solidColor': solidColor?.toARGB32()`.
- `fromJson`: `solidColor: json['solidColor'] != null ? Color(json['solidColor'] as int) : null`.
- Added to the constructor, `copyWith` (plain `Color?` — no clear flag needed; it's simply ignored when `wallpaperCategory != 'Solid'`), and `==`/`hashCode`.
- Semantics: when `wallpaperCategory == 'Solid'` **and** `solidColor != null`, the wallpaper is that exact color. `null` → today's procedural `_solid(index)` (legacy/back-compat).

**`WallpaperRef` color variant** (`packages/screen_recorder/lib/state/wallpaper_ref.dart`):
- `WallpaperRef.color(Color)` → encodes to `color:RRGGBB` (6 hex digits, opaque).
- `decode` learns the `color:` scheme; unknown schemes still return `null` (already the case), so this is purely additive — no favorites migration.
- Value equality covers both variants.

**Rendering** (`wallpaper.dart`):
- `wallpaperDecoration(category, index, {int? thumbCacheWidth, Color? solidColor})` returns `BoxDecoration(color: solidColor)` when `category == 'Solid'` and `solidColor != null`; otherwise unchanged (legacy procedural / photo / gradient).
- The preview canvas (`playback_canvas.dart`) and export (`frame_compositor.dart`) call sites pass `solidColor: frame.solidColor`.
- `wallpaperRepresentativeColor(category, index, {Color? solidColor})` returns `solidColor` for a custom solid, so the inset ring tints correctly.

### UI — a reusable `ColorPickerField`

A standalone widget in `packages/screen_recorder/lib/ui/widgets/inspector/` (so captions/border can reuse it later):

- **Saturation/Brightness square** — a `CustomPaint` (white→hue horizontal × transparent→black vertical) with a draggable thumb; drag updates S/V.
- **Hue slider** — a horizontal rainbow strip with a draggable thumb; drag updates hue.
- **Hex input** — a `#RRGGBB` text field, two-way synced with the square/slider (typing a valid hex moves the thumbs; dragging updates the field).
- **Preset swatches** — a row of ~12 curated solids (neutrals + saturated tones) tap-to-select, styled like the existing caption swatches.
- Emits the selected `Color` via `onChanged` continuously during drag (a solid-color re-render is cheap, so no debounce).
- Pure color math (HSV↔RGB, hex parse/format) extracted as testable top-level functions.

**Solid tab integration** (`background_tab.dart` `_gridRegion`): when `category == 'Solid'`, return the `ColorPickerField` (seeded from `frame.solidColor`, or — when null — the current wallpaper's `wallpaperRepresentativeColor` so the picker opens on the color already on screen, falling back to a neutral grey) instead of the tile grid; `onChanged` → `_updateWallpaper`-style write that sets `wallpaperCategory: 'Solid'` + `solidColor: c`. It's still inside the existing `AnimatedSize`, so the height change vs. the photo grids animates.

### Favorites integration (colors become favoritable)

- A **star toggle on the current-color preview** in the picker (☆ ↔ ★) saves/removes the current color as a `WallpaperRef.color`. Right-clicking a preset swatch favorites that color too (reuses the existing `showMenu` path).
- `_favoritesGrid` learns the color variant: a `color:` ref renders as a plain `BoxDecoration(color:)` swatch tile (photo refs still go through `wallpaperDecoration`). Tapping a color favorite applies `wallpaperCategory: 'Solid'` + `solidColor: <color>`. The sticky-chip + ring logic already keys off `WallpaperRef` equality, so it extends for free.

### Backward compatibility

`_solid(index)` and the procedural path stay for rendering pre-existing projects (`solidColor == null`). The picker only ever writes `solidColor`; it never creates new index-based solids. No migration.

## Testing (TDD)

- **`WindowFrame.solidColor`**: `copyWith` sets/preserves it; `toJson`/`fromJson` round-trip; `==`/`hashCode` include it; absent JSON key → `null`.
- **`WallpaperRef.color`**: encode/decode `color:RRGGBB` round-trip; equality; `decode` still rejects malformed/unknown; photo and color variants are distinct.
- **`wallpaperDecoration`**: `Solid` + `solidColor` → `BoxDecoration(color:)`; `Solid` without → legacy procedural; non-Solid ignores `solidColor`.
- **Color math**: HSV↔RGB and hex parse/format round-trips, including edge hues and invalid hex.
- **Widget (`ColorPickerField`)**: dragging the SV square / hue slider and typing hex all emit the expected `Color`; preset tap selects.
- **Widget (`background_tab`)**: Solid tab shows the picker (not tiles); changing the color writes `frame.solidColor` + `category == 'Solid'`; favoriting the current color adds a `color:` ref; the Favorite tab renders a color favorite and applies it on tap.

## Files

**Modify (engine):**
- `packages/slipreel_engine/lib/models/window_frame.dart` — `solidColor` field (ctor, copyWith, json, ==).
- `packages/slipreel_engine/lib/rendering/wallpaper.dart` — `solidColor` param on `wallpaperDecoration` + `wallpaperRepresentativeColor`.

**Modify (app):**
- `packages/screen_recorder/lib/state/wallpaper_ref.dart` — `color:` variant.
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart` — Solid → picker in `_gridRegion`; color-ref handling in `_favoritesGrid`/apply; favorite-the-current-color.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` + `packages/slipreel_engine/lib/export/frame_compositor.dart` — pass `solidColor: frame.solidColor`.

**Create (app):**
- `packages/screen_recorder/lib/ui/widgets/inspector/color_picker_field.dart` — the reusable picker + color math.

**Tests** under both packages' `test/` trees.

## Follow-up (separate spec, sequenced)

3. **Real photo sets for Sunset/Radial** — Unsplash-licensed assets like macOS/Spring; decide what "Radial" becomes; reuse the picker thumbnail (`thumbCacheWidth`) path to avoid the decode hit.
