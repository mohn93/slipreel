import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/trim_selection.dart';
import 'package:screen_recorder/ui/screens/playback/trim_controller.dart';

void main() {
  group('TrimController', () {
    late int pauses;
    late List<Duration> seeks;
    late TrimController c;
    setUp(() {
      pauses = 0;
      seeks = [];
      c = TrimController(pause: () => pauses++, seekTo: seeks.add);
    });

    test('enforce pauses + seeks to end when playing past trim.end', () {
      c.selection = TrimSelection(
          start: Duration.zero, end: const Duration(seconds: 5));
      c.enforce(isPlaying: true, position: const Duration(seconds: 6));
      expect(pauses, 1);
      expect(seeks.last, const Duration(seconds: 5));
    });

    test('enforce does nothing when not playing', () {
      c.selection = TrimSelection(
          start: Duration.zero, end: const Duration(seconds: 5));
      c.enforce(isPlaying: false, position: const Duration(seconds: 6));
      expect(pauses, 0);
      expect(seeks, isEmpty);
    });

    test('enforce does nothing before trim.end', () {
      c.selection = TrimSelection(
          start: Duration.zero, end: const Duration(seconds: 5));
      c.enforce(isPlaying: true, position: const Duration(seconds: 4));
      expect(pauses, 0);
      expect(seeks, isEmpty);
    });

    test('enforce is a no-op when no selection', () {
      c.enforce(isPlaying: true, position: const Duration(seconds: 6));
      expect(pauses, 0);
      expect(seeks, isEmpty);
    });
  });
}
