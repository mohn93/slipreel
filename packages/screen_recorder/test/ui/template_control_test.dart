import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/template_control.dart';

void main() {
  testWidgets('renders the selected template name and fires onTap',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TemplateControl(
          selectedName: 'Showcase',
          onTap: () => tapped = true,
        ),
      ),
    ));
    expect(find.text('Showcase'), findsOneWidget);
    await tester.tap(find.byType(TemplateControl));
    expect(tapped, isTrue);
  });
}
