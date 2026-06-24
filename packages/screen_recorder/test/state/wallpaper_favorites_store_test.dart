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
