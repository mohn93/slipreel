import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';

void main() {
  KeystrokeEvent e(int ms, String label) =>
      KeystrokeEvent(timestampMicros: ms * 1000, label: label);

  group('KeystrokeRecording chronological ingestion', () {
    // eventsInRange binary-searches assuming ascending timestamps, but
    // addEvent never enforced it — an out-of-order sidecar line broke
    // range queries after the inversion. addEvent must keep order.
    test('out-of-order addEvent keeps events sorted', () {
      final rec = KeystrokeRecording();
      rec.addEvent(e(0, 'a'));
      rec.addEvent(e(200, 'c'));
      rec.addEvent(e(100, 'b')); // late arrival
      expect(
        rec.events.map((k) => k.label).toList(),
        ['a', 'b', 'c'],
      );
    });

    test('range queries stay correct after an out-of-order append', () {
      final rec = KeystrokeRecording();
      rec.addEvent(e(0, 'a'));
      rec.addEvent(e(200, 'c'));
      rec.addEvent(e(100, 'b'));
      final hits = rec.eventsInRange(50 * 1000, 150 * 1000);
      expect(hits.map((k) => k.label).toList(), ['b']);
    });

    test('in-order appends preserve order', () {
      final rec = KeystrokeRecording();
      for (var i = 0; i < 4; i++) {
        rec.addEvent(e(i * 100, '$i'));
      }
      expect(rec.events.map((k) => k.label).toList(), ['0', '1', '2', '3']);
    });
  });
}
