import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/shareable_link_panel.dart';

void main() {
  Widget build({
    String title = 'My Recording',
    bool isPrivate = false,
    ValueChanged<String>? onTitleChanged,
    ValueChanged<bool>? onIsPrivateChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ShareableLinkPanel(
          title: title,
          isPrivate: isPrivate,
          onTitleChanged: onTitleChanged ?? (_) {},
          onIsPrivateChanged: onIsPrivateChanged ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('renders Video title label and text field', (tester) async {
    await tester.pumpWidget(build());
    expect(find.text('Video title'), findsOneWidget);
    expect(find.byKey(const ValueKey('shareable_title_field')), findsOneWidget);
  });

  testWidgets('text field shows the passed-in title', (tester) async {
    await tester.pumpWidget(build(title: 'Demo Export'));
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('shareable_title_field')),
    );
    expect(field.controller!.text, 'Demo Export');
  });

  testWidgets('typing in field fires onTitleChanged', (tester) async {
    String? fired;
    await tester.pumpWidget(build(onTitleChanged: (v) => fired = v));
    await tester.enterText(
      find.byKey(const ValueKey('shareable_title_field')),
      'New Title',
    );
    await tester.pump();
    expect(fired, 'New Title');
  });

  testWidgets('renders Private label and switch', (tester) async {
    await tester.pumpWidget(build());
    expect(find.text('Private'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shareable_private_switch')),
      findsOneWidget,
    );
  });

  testWidgets('switch reflects isPrivate value', (tester) async {
    await tester.pumpWidget(build(isPrivate: true));
    final sw = tester.widget<Switch>(
      find.byKey(const ValueKey('shareable_private_switch')),
    );
    expect(sw.value, isTrue);
  });

  testWidgets('toggling switch fires onIsPrivateChanged', (tester) async {
    bool? fired;
    await tester.pumpWidget(
      build(isPrivate: false, onIsPrivateChanged: (v) => fired = v),
    );
    await tester.tap(find.byKey(const ValueKey('shareable_private_switch')));
    await tester.pump();
    expect(fired, isTrue);
  });

  testWidgets('renders privacy subtitle text', (tester) async {
    await tester.pumpWidget(build());
    expect(
      find.text(
        'Only the people you share this video with will be able to watch it.',
      ),
      findsOneWidget,
    );
  });

  // --- controller-sync / focus tests ---

  testWidgets(
      'controller text does NOT update when field is focused and parent changes value',
      (tester) async {
    // Use a StatefulWidget harness so we can change the title from outside.
    String currentTitle = 'Original';
    late StateSetter setStateRef;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setStateRef = setState;
          return MaterialApp(
            home: Scaffold(
              body: ShareableLinkPanel(
                title: currentTitle,
                isPrivate: false,
                onTitleChanged: (_) {},
                onIsPrivateChanged: (_) {},
              ),
            ),
          );
        },
      ),
    );

    // Focus the text field by tapping it.
    await tester.tap(find.byKey(const ValueKey('shareable_title_field')));
    await tester.pump();

    // Parent pushes a new value while field is focused.
    setStateRef(() => currentTitle = 'Parent Normalized');
    await tester.pump();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('shareable_title_field')),
    );
    // The controller text should remain 'Original' — not clobbered.
    expect(field.controller!.text, 'Original');
  });

  testWidgets(
      'controller text DOES update when field is not focused and parent changes value',
      (tester) async {
    String currentTitle = 'Original';
    late StateSetter setStateRef;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setStateRef = setState;
          return MaterialApp(
            home: Scaffold(
              body: ShareableLinkPanel(
                title: currentTitle,
                isPrivate: false,
                onTitleChanged: (_) {},
                onIsPrivateChanged: (_) {},
              ),
            ),
          );
        },
      ),
    );

    // Field is NOT focused — just update the parent value.
    setStateRef(() => currentTitle = 'New Value');
    await tester.pump();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('shareable_title_field')),
    );
    expect(field.controller!.text, 'New Value');
  });
}
