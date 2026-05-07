import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/screen_pan_velocity_tracker.dart';

Matrix4 _translation(double dx, double dy) =>
    Matrix4.translationValues(dx, dy, 0);

void main() {
  group('ScreenPanVelocityTracker', () {
    test('first call after construction returns zero', () {
      final t = ScreenPanVelocityTracker();
      final v = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 0),
      );
      expect(v, Offset.zero);
    });

    test('two calls with translation Δ=(20,0) over 16ms → ~1250 px/s on x', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 0),
      );
      final v = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      expect(v.dx, closeTo(1250.0, 1.0));
      expect(v.dy, closeTo(0, 1e-6));
    });

    test('same position called twice returns cached velocity, no state advance', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 0),
      );
      final v1 = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      // Calling at the same position must NOT update _last; otherwise
      // a subsequent forward step would see a fake Δt of 0.
      final v1Again = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      expect(v1Again, v1);
      // Now advance forward — state should have advanced from the
      // FIRST call only, not the duplicate.
      final v2 = t.update(
        transform: _translation(40, 0),
        position: const Duration(milliseconds: 32),
      );
      expect(v2.dx, closeTo(1250.0, 1.0));
    });

    test('reset clears state — first call after reset returns zero', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 0),
      );
      t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      t.reset();
      final v = t.update(
        transform: _translation(60, 0),
        position: const Duration(milliseconds: 32),
      );
      expect(v, Offset.zero);
    });

    test('backwards position returns zero (no negative-Δt blowup)', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 100),
      );
      final v = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 50),
      );
      expect(v, Offset.zero);
    });
  });
}
