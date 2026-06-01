import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

void main() {
  testWidgets('context.palette returns the palette installed on ThemeData',
      (tester) async {
    AppPalette? captured;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.carbon],
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) {
          captured = context.palette;
          return const SizedBox.shrink();
        },
      ),
    ));
    expect(captured, AppPalette.carbon);
  });
}
