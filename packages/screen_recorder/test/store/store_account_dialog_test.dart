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

class SignInAccount extends FakeAccount {
  SignInAccount(super.licensing) {
    email = null;
    appAccountToken = null;
  }
  @override
  Future<String> sendCode(String email) async => 'test-challenge';
}

void main() {
  Future<void> host(
    WidgetTester tester, {
    double scale = 1,
    bool empty = false,
    bool signedOut = false,
  }) async {
    final c = FakeLicensing(FakeStore());
    if (!empty) c.setAccess(paid());
    final a = signedOut
        ? SignInAccount(c)
        : (empty ? EmptyAccount(c) : FakeAccount(c));
    if (!signedOut) a.email = 'qa.account@example.com';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          licensingControllerProvider.overrideWith((ref) => c),
          nativeAccountProvider.overrideWith((ref) => a),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'Roboto',
            colorScheme: AppPalette.midnight.toColorScheme(),
            extensions: [AppPalette.midnight],
            useMaterial3: true,
          ),
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

  testWidgets('email validation and keyboard code entry', (tester) async {
    await host(tester, signedOut: true);
    await tester.tap(find.text('Continue with email'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a valid email'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'tester@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Check your inbox'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter the 8-digit code from your email.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Change email or send a new code'));
    await tester.pumpAndSettle();
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Enter the 8-digit code from your email.'), findsNothing);
  });
  testWidgets('sign-in fits narrow windows with large text', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await host(tester, signedOut: true, scale: 1.5);
    await tester.ensureVisible(find.text('Continue with email'));
    expect(tester.takeException(), isNull);
  });

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
    await tester.pumpWidget(const SizedBox());
    await host(tester, signedOut: true);
    await expectLater(
      find.byKey(const Key('account-preview')),
      matchesGoldenFile('$directory/sign-in.png'),
    );
    await tester.enterText(find.byType(TextField), 'tester@example.com');
    await tester.tap(find.text('Continue with email'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('account-preview')),
      matchesGoldenFile('$directory/sign-in-code.png'),
    );
  });
}
