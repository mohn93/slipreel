import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/waveform_painter.dart';

void main() {
  group('waveformPoints', () {
    test('maps samples across width, taller sample sits higher', () {
      const size = Size(100, 40);
      final pts = waveformPoints(const [0.0, 1.0], size, 0.6);
      expect(pts.length, 2);
      expect(pts.first.dx, 0.0);
      expect(pts.last.dx, 100.0);
      // y grows downward: the louder (1.0) sample has the smaller y.
      expect(pts.last.dy, lessThan(pts.first.dy));
      // 1.0 sample reaches 60% of height up from the bottom (40 * 0.6 = 24).
      expect(pts.last.dy, closeTo(40 - 24, 1e-6));
    });

    test('empty / single sample -> empty points', () {
      expect(waveformPoints(const [], const Size(10, 10), 0.6), isEmpty);
      expect(waveformPoints(const [0.5], const Size(10, 10), 0.6), isEmpty);
    });
  });

  group('buildSmoothPath', () {
    test('path spans the full width', () {
      final pts = waveformPoints(
        List<double>.generate(20, (i) => (i % 5) / 5),
        const Size(200, 40),
        0.6,
      );
      final path = buildSmoothPath(pts);
      final b = path.getBounds();
      expect(b.left, closeTo(0, 1.0));
      expect(b.right, closeTo(200, 2.0));
    });
  });

  testWidgets('painter renders without throwing', (tester) async {
    await tester.pumpWidget(
      Center(
        child: CustomPaint(
          size: const Size(120, 46),
          painter: WaveformPainter(
            samples: List<double>.generate(40, (i) => (i % 7) / 7),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
