import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

void main() {
  test('keeps only the most recent `capacity` entries, oldest-first', () {
    final b = Breadcrumbs(capacity: 3);
    for (var i = 1; i <= 5; i++) {
      b.add(zone: 'UI', level: 'INFO', message: 'm$i');
    }
    final snap = b.snapshot();
    expect(snap.length, 3);
    expect(snap.first, contains('m3'));
    expect(snap.last, contains('m5'));
    expect(snap.last, contains('[UI]'));
  });

  test('truncates long messages at insert time', () {
    final b = Breadcrumbs(capacity: 2, maxMessageLength: 5);
    b.add(zone: 'UI', level: 'INFO', message: 'abcdefghij');
    expect(b.snapshot().single, contains('abcde'));
    expect(b.snapshot().single, isNot(contains('fghij')));
  });
}
