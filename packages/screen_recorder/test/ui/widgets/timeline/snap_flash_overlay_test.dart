import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:screen_recorder/ui/widgets/timeline/snap_flash_overlay.dart';

void main() {
  testWidgets('renders nothing when target is null', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 60,
          child: SnapFlashOverlay(
            target: null,
            editedTimeToPx: _identityMapper,
          ),
        ),
      ),
    ));
    final overlay = tester.widget<SnapFlashOverlay>(find.byType(SnapFlashOverlay));
    expect(overlay.target, isNull);
  });

  testWidgets('renders glow at mapped pixel when target is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 60,
          child: SnapFlashOverlay(
            target: const Duration(seconds: 2),
            editedTimeToPx: (d) => d.inMilliseconds.toDouble() / 10.0,
          ),
        ),
      ),
    ));
    final overlay = tester.widget<SnapFlashOverlay>(find.byType(SnapFlashOverlay));
    expect(overlay.target, const Duration(seconds: 2));
  });
}

double _identityMapper(Duration d) => d.inMilliseconds.toDouble();
