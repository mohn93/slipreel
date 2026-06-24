// packages/screen_recorder/test/ui/widgets/inspector/color_picker_field_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/color_picker_field.dart';

void main() {
  test('parseHexColor parses #RRGGBB and RRGGBB; rejects bad input', () {
    expect(parseHexColor('#FF8800'), const Color(0xFFFF8800));
    expect(parseHexColor('ff8800'), const Color(0xFFFF8800));
    expect(parseHexColor('  #00FF00 '), const Color(0xFF00FF00));
    expect(parseHexColor('FFF'), isNull);
    expect(parseHexColor('GGGGGG'), isNull);
  });

  test('formatHexColor returns uppercase #RRGGBB', () {
    expect(formatHexColor(const Color(0xFF12ab34)), '#12AB34');
  });

  Widget host(Color color, ValueChanged<Color> onChanged) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 240, child: ColorPickerField(
            color: color, onChanged: onChanged)),
        ),
      );

  testWidgets('tapping a preset emits that color', (tester) async {
    Color? out;
    await tester.pumpWidget(host(const Color(0xFF000000), (c) => out = c));
    await tester.tap(find.byKey(ValueKey('preset-${kSolidPresetColors.last.toARGB32()}')));
    await tester.pump();
    expect(out, kSolidPresetColors.last);
  });

  testWidgets('submitting a hex value emits the parsed color', (tester) async {
    Color? out;
    await tester.pumpWidget(host(const Color(0xFF000000), (c) => out = c));
    await tester.enterText(find.byType(TextField), '#3366CC');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(out, const Color(0xFF3366CC));
  });

  testWidgets('dragging the SV square emits a new color', (tester) async {
    Color? out;
    await tester.pumpWidget(host(const Color(0xFFFF0000), (c) => out = c));
    await tester.drag(find.byKey(const Key('sv-square')), const Offset(-30, 10));
    await tester.pump();
    expect(out, isNotNull);
  });
}
