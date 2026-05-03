import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/frame_rate_picker.dart';

void main() {
  Widget build({
    required int value,
    List<int> options = kFrameRateOptions,
    required ValueChanged<int> onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FrameRatePicker(
          value: value,
          options: options,
          onChanged: onChanged,
        ),
      ),
    );
  }

  testWidgets('shows current frame rate in closed state', (tester) async {
    await tester.pumpWidget(build(value: 30, onChanged: (_) {}));
    expect(find.text('30 fps'), findsOneWidget);
  });

  testWidgets('shows section header', (tester) async {
    await tester.pumpWidget(build(value: 30, onChanged: (_) {}));
    expect(find.text('Frame rate'), findsOneWidget);
  });

  testWidgets('opens menu when tapped', (tester) async {
    await tester.pumpWidget(build(value: 30, onChanged: (_) {}));
    await tester.tap(find.byKey(const ValueKey('frame_rate_popup')));
    await tester.pumpAndSettle();
    // After opening, all fps options should be visible.
    for (final fps in kFrameRateOptions) {
      expect(find.text('$fps fps'), findsAtLeastNWidgets(1));
    }
  });

  testWidgets('fires onChanged when an option is tapped', (tester) async {
    int? fired;
    await tester.pumpWidget(build(value: 30, onChanged: (v) => fired = v));
    await tester.tap(find.byKey(const ValueKey('frame_rate_popup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fps_option_60')));
    await tester.pumpAndSettle();
    expect(fired, 60);
  });

  testWidgets('menu closes after selecting an option', (tester) async {
    await tester.pumpWidget(build(value: 30, onChanged: (_) {}));
    await tester.tap(find.byKey(const ValueKey('frame_rate_popup')));
    await tester.pumpAndSettle();
    // Menu is open — items are visible.
    expect(find.byType(PopupMenuItem<int>), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('fps_option_60')));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<int>), findsNothing);
  });

  testWidgets('checkmark appears beside selected value in menu', (tester) async {
    await tester.pumpWidget(build(value: 30, onChanged: (_) {}));
    await tester.tap(find.byKey(const ValueKey('frame_rate_popup')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('accepts a custom options list (GIF subset)', (tester) async {
    const gifOptions = [30, 25, 24, 20, 15, 10];
    await tester.pumpWidget(
      build(value: 15, options: gifOptions, onChanged: (_) {}),
    );
    expect(find.text('15 fps'), findsOneWidget);
    // 60 fps is not in gif subset — should not appear before menu opens
    expect(find.text('60 fps'), findsNothing);
  });
}
