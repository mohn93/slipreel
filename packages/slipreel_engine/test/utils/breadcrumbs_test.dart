import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

void main() {
  test('dropEvent records the event name and props', () {
    final b = Breadcrumbs(capacity: 5);
    b.dropEvent('export_started', props: {'format': 'mp4'});
    final snap = b.snapshot();
    expect(snap, hasLength(1));
    expect(snap.single, contains('export_started'));
    expect(snap.single, contains('format=mp4'));
  });

  test('a no-props event formats as event:<name>', () {
    final b = Breadcrumbs(capacity: 5);
    b.dropEvent('recording_started');
    expect(b.snapshot().single, 'event:recording_started');
  });

  test('keeps only the most recent `capacity` entries, oldest-first', () {
    final b = Breadcrumbs(capacity: 3);
    for (var i = 1; i <= 5; i++) {
      b.dropEvent('event_$i');
    }
    final snap = b.snapshot();
    expect(snap.length, 3);
    expect(snap.first, contains('event_3'));
    expect(snap.last, contains('event_5'));
  });

  test('truncates long messages at insert time', () {
    final b = Breadcrumbs(capacity: 2, maxMessageLength: 12);
    b.dropEvent('abcdefghijklmnopqrst');
    expect(b.snapshot().single.length, 12);
  });
}
