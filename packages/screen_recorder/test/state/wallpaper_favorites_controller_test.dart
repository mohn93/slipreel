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
