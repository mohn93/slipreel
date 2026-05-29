import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recovery_service.dart';
import 'package:screen_recorder/state/session_marker.dart';
import 'package:screen_recorder/ui/widgets/recovery_modal.dart';

RecoveryCandidate _cand(String id) => RecoveryCandidate(
      marker: SessionMarker(
        id: id,
        videoPath: '/tmp/$id.mp4',
        cursorNdjsonPath: '/tmp/$id.ndjson',
        startedAt: DateTime.utc(2026, 5, 29, 15, 30),
        width: 1920,
        height: 1080,
        fps: 60,
      ),
      videoBytes: 1024 * 1024,
    );

void main() {
  testWidgets('renders one row per candidate', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1'), _cand('s2'), _cand('s3')],
          onRecover: (_) async => '/tmp/out.mp4',
          onDiscard: (_) async {},
        ),
      ),
    ));
    expect(find.text('s1'), findsNothing); // we don't show raw ids
    expect(find.byKey(const Key('recovery-row')), findsNWidgets(3));
  });

  testWidgets('Recover button calls onRecover', (tester) async {
    String? recovered;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1')],
          onRecover: (c) async {
            recovered = c.marker.id;
            return '/tmp/out.mp4';
          },
          onDiscard: (_) async {},
        ),
      ),
    ));
    await tester.tap(find.text('Recover').first);
    await tester.pumpAndSettle();
    expect(recovered, 's1');
  });

  testWidgets('Discard button calls onDiscard', (tester) async {
    String? discarded;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1')],
          onRecover: (_) async => null,
          onDiscard: (c) async => discarded = c.marker.id,
        ),
      ),
    ));
    await tester.tap(find.text('Discard').first);
    await tester.pumpAndSettle();
    expect(discarded, 's1');
  });

  testWidgets('Discard all loops over rows', (tester) async {
    final discarded = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1'), _cand('s2')],
          onRecover: (_) async => null,
          onDiscard: (c) async => discarded.add(c.marker.id),
        ),
      ),
    ));
    await tester.tap(find.text('Discard all'));
    await tester.pumpAndSettle();
    expect(discarded, ['s1', 's2']);
  });
}
