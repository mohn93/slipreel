@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/recents_screen.dart';
import 'package:screen_recorder/ui/screens/recents/recording_card.dart';

void main() {
  testWidgets('renders a GridView of RecordingCards from the store', (tester) async {
    final store = RecordingHistoryStore.inMemory([
      RecordingHistoryEntry(
          videoPath: '/tmp/a.mp4', recordedAt: DateTime(2026, 5, 14),
          widthPx: 1920, heightPx: 1080, fps: 60),
      RecordingHistoryEntry(
          videoPath: '/tmp/b.mp4', recordedAt: DateTime(2026, 5, 13),
          widthPx: 1280, heightPx: 720, fps: 30),
    ]);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: RecentsScreen(store: store)));
      // Allow _refresh's async I/O chain (load + File.exists × 2) to complete.
      await Future.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(); // build with the resolved state
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(RecordingCard), findsNWidgets(2));
  });
}
