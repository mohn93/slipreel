import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/store/native_account.dart';
import 'package:screen_recorder/store/store_account_dialog.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'store_paywall_test.dart'
    show FakeLicensing, FakeStore, FakeAccount, paid;

class EmptyAccount extends FakeAccount {
  EmptyAccount(super.licensing);
  @override
  Future<void> syncPurchases() async {}
}

void main() {
  Future<void> host(
    WidgetTester tester, {
    double scale = 1,
    bool empty = false,
  }) async {
    final c = FakeLicensing(FakeStore());
    if (!empty) c.setAccess(paid());
    final a = (empty ? EmptyAccount(c) : FakeAccount(c))
      ..email = 'qa.account@example.com';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          licensingControllerProvider.overrideWith((ref) => c),
          nativeAccountProvider.overrideWith((ref) => a),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(extensions: [AppPalette.midnight]),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: const Key('account-preview'),
            child: Scaffold(
              backgroundColor: AppPalette.midnight.appBackground,
              body: const Dialog(
                insetPadding: EdgeInsets.all(24),
                child: SizedBox(width: 520, child: StoreAccountDialog()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sync feedback and deletion confirmation remain usable', (
    tester,
  ) async {
    await host(tester);
    await tester.tap(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    expect(
      find.text('Your purchases and access are up to date.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your Slipreel account?'), findsOneWidget);
    await tester.tap(find.text('Keep account'));
    await tester.pumpAndSettle();
    expect(find.text('qa.account@example.com'), findsOneWidget);
  });
  testWidgets('empty restore does not report successful access', (
    tester,
  ) async {
    await host(tester, empty: true);
    await tester.tap(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No active purchase found.'), findsOneWidget);
    expect(
      find.text('Your purchases and access are up to date.'),
      findsNothing,
    );
    expect(find.text('Manage subscription'), findsNothing);
  });

  testWidgets('account fits narrow windows with large text', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await host(tester, scale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Delete account'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('account visual preview capture', (tester) async {
    final directory = Platform.environment['SLIPREEL_UI_CAPTURE'];
    if (directory == null) return;
    for (final font in [
      ('Roboto', 'SLIPREEL_UI_FONT'),
      ('MaterialIcons', 'SLIPREEL_UI_ICONS'),
    ]) {
      final path = Platform.environment[font.$2];
      if (path == null) continue;
      final loader = FontLoader(font.$1)
        ..addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
        );
      await tester.runAsync(loader.load);
    }
    tester.view.physicalSize = const Size(680, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await host(tester);
    await expectLater(
      find.byKey(const Key('account-preview')),
      matchesGoldenFile('$directory/account.png'),
    );
  });
}
