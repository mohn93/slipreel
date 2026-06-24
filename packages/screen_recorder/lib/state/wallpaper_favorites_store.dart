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
