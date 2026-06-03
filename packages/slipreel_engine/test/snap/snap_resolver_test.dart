// packages/slipreel_engine/test/snap/snap_resolver_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/snap/snap_resolver.dart';

void main() {
  Duration ms(int n) => Duration(milliseconds: n);

  group('resolveSnap', () {
    test('empty candidates returns requested time with no snap', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: const []);
      expect(r.time, ms(1000));
      expect(r.snappedFrom, isNull);
    });

    test('exact-hit candidate snaps with snappedFrom == requestedTime', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1000)]);
      expect(r.time, ms(1000));
      expect(r.snappedFrom, ms(1000));
    });

    test('candidate inside radius snaps (149ms away)', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1149)]);
      expect(r.time, ms(1149));
      expect(r.snappedFrom, ms(1149));
    });

    test('candidate exactly at radius (150ms) snaps (<= semantics)', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1150)]);
      expect(r.time, ms(1150));
      expect(r.snappedFrom, ms(1150));
    });

    test('candidate just outside radius (151ms) does not snap', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1151)]);
      expect(r.time, ms(1000));
      expect(r.snappedFrom, isNull);
    });

    test('equidistant ties go to the earlier candidate', () {
      final r = resolveSnap(
        requestedTime: ms(1000),
        candidates: [ms(900), ms(1100)],
      );
      expect(r.time, ms(900));
      expect(r.snappedFrom, ms(900));
    });

    test('picks the nearest of many candidates', () {
      final r = resolveSnap(
        requestedTime: ms(1000),
        candidates: [ms(500), ms(900), ms(1050), ms(2000)],
      );
      expect(r.time, ms(1050));
      expect(r.snappedFrom, ms(1050));
    });

    test('requestedTime before all candidates checks only the first', () {
      final r = resolveSnap(
        requestedTime: ms(10),
        candidates: [ms(50), ms(500), ms(2000)],
      );
      expect(r.time, ms(50));
      expect(r.snappedFrom, ms(50));
    });

    test('requestedTime after all candidates checks only the last', () {
      final r = resolveSnap(
        requestedTime: ms(5000),
        candidates: [ms(100), ms(500), ms(4900)],
      );
      expect(r.time, ms(4900));
      expect(r.snappedFrom, ms(4900));
    });

    test('preserves microsecond precision', () {
      final t = const Duration(microseconds: 1234567);
      final r = resolveSnap(requestedTime: t, candidates: [t]);
      expect(r.time, t);
      expect(r.snappedFrom, t);
    });

    test('custom radius is respected', () {
      // 80ms radius: 100ms candidate is outside, no snap.
      final r = resolveSnap(
        requestedTime: ms(1000),
        candidates: [ms(1100)],
        radius: ms(80),
      );
      expect(r.time, ms(1000));
      expect(r.snappedFrom, isNull);
    });
  });
}
