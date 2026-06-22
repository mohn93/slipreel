import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/caption_segment_list.dart';

void main() {
  testWidgets('renders a row per segment and edits text', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(editorProjectControllerProvider.notifier)
        .replaceCaptionSegments(const [
      CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000000, text: 'one'),
      CaptionSegment(
          id: 'b', startMicros: 1000000, endMicros: 2000000, text: 'two'),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: CaptionSegmentList()),
        ),
      ),
    );
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, 'edited');
    await tester.pump();
    expect(
      container.read(editorProjectControllerProvider).captions.first.text,
      'edited',
    );
  });
}
