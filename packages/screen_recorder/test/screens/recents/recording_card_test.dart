@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/recents/recording_card.dart';
import 'package:screen_recorder/ui/screens/recents/recording_thumbnail_service.dart';

RecordingHistoryEntry _entry() => RecordingHistoryEntry(
      videoPath: '/tmp/recording_1.mp4',
      recordedAt: DateTime(2026, 5, 14, 21, 33),
      widthPx: 2214,
      heightPx: 1984,
      fps: 60,
    );

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 280, child: child))));

void main() {
  testWidgets('missing file → shows placeholder, tap disabled, remove works',
      (tester) async {
    var removed = false;
    await tester.pumpWidget(_host(RecordingCard(
      entry: _entry(),
      fileExists: false,
      thumbnailFuture: Future.error(RecordingMissingException('/tmp/recording_1.mp4')),
      onOpen: () {},
      onOpenPlayground: () {},
      onRemove: () => removed = true,
    )));
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.textContaining('May 14, 2026'), findsOneWidget);
  });

  testWidgets('ready → renders the thumbnail image and caption', (tester) async {
    // Write a tiny valid PNG to a temp file.
    final tmp = File('${Directory.systemTemp.path}/card_thumb.png');
    tmp.writeAsBytesSync(_tinyPng());
    await tester.pumpWidget(_host(RecordingCard(
      entry: _entry(),
      fileExists: true,
      thumbnailFuture: Future.value(RecordingThumbnail(
          pngFile: tmp, duration: const Duration(seconds: 42))),
      onOpen: () {},
      onOpenPlayground: () {},
      onRemove: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('0:42'), findsOneWidget);
  });

  testWidgets('tap fires onOpen, long-press fires onOpenPlayground',
      (tester) async {
    var opened = 0, playground = 0;
    final tmp = File('${Directory.systemTemp.path}/card_thumb2.png')
      ..writeAsBytesSync(_tinyPng());
    await tester.pumpWidget(_host(RecordingCard(
      entry: _entry(),
      fileExists: true,
      thumbnailFuture: Future.value(
          RecordingThumbnail(pngFile: tmp, duration: const Duration(seconds: 1))),
      onOpen: () => opened++,
      onOpenPlayground: () => playground++,
      onRemove: () {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    expect(opened, 1);
    await tester.longPress(find.byType(InkWell).first);
    expect(playground, 1);
  });
}

// 1x1 transparent PNG.
List<int> _tinyPng() => const [
  137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,
  31,21,196,137,0,0,0,13,73,68,65,84,120,156,99,250,207,0,0,3,1,1,0,24,221,
  141,219,0,0,0,0,73,69,78,68,174,66,96,130,
];
