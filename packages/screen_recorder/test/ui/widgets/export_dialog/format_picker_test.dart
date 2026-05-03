import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/format_picker.dart';

void main() {
  Widget build({
    required ExportFormat value,
    required ValueChanged<ExportFormat> onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FormatPicker(value: value, onChanged: onChanged),
      ),
    );
  }

  testWidgets('renders MP4 and GIF options', (tester) async {
    await tester.pumpWidget(build(value: ExportFormat.mp4, onChanged: (_) {}));
    expect(find.text('MP4'), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget);
  });

  testWidgets('shows Format section header with icon', (tester) async {
    await tester.pumpWidget(build(value: ExportFormat.mp4, onChanged: (_) {}));
    expect(find.text('Format'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });

  testWidgets('tapping GIF fires onChanged(ExportFormat.gif)', (tester) async {
    ExportFormat? fired;
    await tester.pumpWidget(
      build(value: ExportFormat.mp4, onChanged: (v) => fired = v),
    );
    await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.gif')));
    await tester.pump();
    expect(fired, ExportFormat.gif);
  });

  testWidgets('tapping MP4 when already MP4 does not fire', (tester) async {
    var callCount = 0;
    await tester.pumpWidget(
      build(value: ExportFormat.mp4, onChanged: (_) => callCount++),
    );
    await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.mp4')));
    await tester.pump();
    expect(callCount, 0);
  });

  testWidgets('tapping MP4 when GIF selected fires onChanged(mp4)',
      (tester) async {
    ExportFormat? fired;
    await tester.pumpWidget(
      build(value: ExportFormat.gif, onChanged: (v) => fired = v),
    );
    await tester.tap(find.byKey(const ValueKey('seg_btn_ExportFormat.mp4')));
    await tester.pump();
    expect(fired, ExportFormat.mp4);
  });
}
