import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/activation_success_dialog.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

const message =
    'Your subscription is active on this Mac. Make something worth sharing.';
void main() {
  testWidgets('actions return to creation or open account', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: [AppPalette.midnight]),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (_) =>
                      const ActivationSuccessDialog(message: message),
                );
              },
              child: const Text('Activate'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    expect(find.text('Unlimited exports unlocked'), findsOneWidget);
    await tester.tap(find.text('Let’s create'));
    await tester.pumpAndSettle();
    expect(result, false);
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage account'));
    await tester.pumpAndSettle();
    expect(result, true);
  });
  testWidgets('compact window and enlarged text with reduced motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: [AppPalette.carbon]),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(360, 440),
            textScaler: TextScaler.linear(1.6),
            disableAnimations: true,
          ),
          child: ActivationSuccessDialog(
            message:
                'Your one-time license is active on this Mac. Make something worth sharing.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Manage account'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('success artwork renders in app palette', (tester) async {
    tester.view.physicalSize = const Size(680, 580);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final output = Platform.environment['SLIPREEL_CAPTURE_ACTIVATION'];
    if (output != null) {
      await tester.runAsync(() async {
        final loader = FontLoader('Preview');
        loader.addFont(
          File(
            '/System/Library/Fonts/SFNS.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
        await loader.load();
      });
    }
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: output != null ? 'Preview' : null,
            extensions: [AppPalette.carbon],
          ),
          home: const Scaffold(
            backgroundColor: Color(0xFF09090B),
            body: ActivationSuccessDialog(message: message),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (output != null) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
