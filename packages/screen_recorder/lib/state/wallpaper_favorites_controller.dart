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
