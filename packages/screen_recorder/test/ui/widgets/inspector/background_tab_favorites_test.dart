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
import 'package:screen_recorder/ui/theme/app_palette.dart';
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
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: const Scaffold(body: BackgroundTab()),
    ),
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
    expect(find.text('Add to Favorites'), findsNothing); // menu dismissed
    expect(find.byIcon(Icons.star), findsOneWidget); // badge on the tile
  });
}
