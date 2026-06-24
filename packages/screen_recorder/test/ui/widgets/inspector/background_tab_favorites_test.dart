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
}
