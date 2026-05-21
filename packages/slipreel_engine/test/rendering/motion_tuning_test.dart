import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';

void main() {
  group('MotionTuning', () {
    test('defaults preserve the historic hand-tuned constants', () {
      // These values are the production tuning frozen as of P2-8.
      // Changing one means changing the perceived feel of the editor;
      // do it deliberately and update the test alongside.
      const t = MotionTuning.defaults;
      expect(t.reverseScrubFloor.inMilliseconds, 200);
      expect(t.subStepCapMicros.inMilliseconds, 16);
      expect(t.dtCap.inMilliseconds, 250);
      expect(t.cursorAtRestPxPerSec, 80.0);
      expect(t.cursorVelocityLookback.inMilliseconds, 33);
      expect(t.cursorFeedforwardStrength, 0.5);
      expect(t.cursorFeedforwardFadeStartPxPerSec, 200.0);
      expect(t.cursorFeedforwardFullSpeedPxPerSec, 800.0);
    });

    test('snappy preset tightens cursor follow vs defaults', () {
      const def = MotionTuning.defaults;
      const snappy = MotionTuning.snappy;

      expect(snappy.cursorAtRestPxPerSec, lessThanOrEqualTo(def.cursorAtRestPxPerSec),
          reason: 'Snappy releases the gate sooner so it should accept a '
              'lower "at-rest" velocity (or equal)');
      expect(snappy.cursorFeedforwardStrength,
          greaterThanOrEqualTo(def.cursorFeedforwardStrength),
          reason: 'Snappy compensates more of the spring lag — higher '
              'feedforward strength puts the sprite closer to the raw path');
    });

    test('cinematic preset slackens cursor follow vs defaults', () {
      const def = MotionTuning.defaults;
      const cine = MotionTuning.cinematic;

      expect(cine.cursorFeedforwardStrength,
          lessThanOrEqualTo(def.cursorFeedforwardStrength),
          reason: 'Cinematic preserves the spring lag for a more film-y feel');
    });

    test('toJson + fromJson round-trip preserves every field', () {
      const original = MotionTuning(
        reverseScrubFloor: Duration(milliseconds: 175),
        subStepCapMicros: Duration(milliseconds: 8),
        dtCap: Duration(milliseconds: 300),
        cursorAtRestPxPerSec: 65.0,
        cursorVelocityLookback: Duration(milliseconds: 50),
        cursorFeedforwardStrength: 0.75,
        cursorFeedforwardFadeStartPxPerSec: 150.0,
        cursorFeedforwardFullSpeedPxPerSec: 900.0,
      );

      final json = original.toJson();
      final round = MotionTuning.fromJson(json);

      expect(round.reverseScrubFloor, original.reverseScrubFloor);
      expect(round.subStepCapMicros, original.subStepCapMicros);
      expect(round.dtCap, original.dtCap);
      expect(round.cursorAtRestPxPerSec, original.cursorAtRestPxPerSec);
      expect(round.cursorVelocityLookback, original.cursorVelocityLookback);
      expect(round.cursorFeedforwardStrength, original.cursorFeedforwardStrength);
      expect(
        round.cursorFeedforwardFadeStartPxPerSec,
        original.cursorFeedforwardFadeStartPxPerSec,
      );
      expect(
        round.cursorFeedforwardFullSpeedPxPerSec,
        original.cursorFeedforwardFullSpeedPxPerSec,
      );
    });

    test('fromJson fills missing fields with defaults', () {
      // A user-edited JSON config may omit fields they don't care about
      // — those should fall back to the production defaults, not crash.
      final partial = <String, dynamic>{
        'cursorAtRestPxPerSec': 120.0,
      };
      final tuning = MotionTuning.fromJson(partial);
      expect(tuning.cursorAtRestPxPerSec, 120.0);
      expect(tuning.cursorFeedforwardStrength,
          MotionTuning.defaults.cursorFeedforwardStrength);
      expect(tuning.dtCap, MotionTuning.defaults.dtCap);
    });

    test('controllers default to MotionTuning.defaults', () {
      // The wiring should be behavior-neutral when no override is
      // passed — production code paths get the historic constants.
      expect(
        ZoomFocalController().tuning,
        same(MotionTuning.defaults),
      );
      expect(
        CursorMotionController().tuning,
        same(MotionTuning.defaults),
      );
    });

    test('controllers honour a custom tuning passed at construction', () {
      // Regression guard: if someone re-introduces a `static const`
      // inside the controller and shadows the tuning field, the
      // controller's exposed tuning would drift from what it actually
      // uses. The .tuning getter is the contract; this test locks it
      // in.
      const custom = MotionTuning(cursorAtRestPxPerSec: 200.0);
      expect(ZoomFocalController(tuning: custom).tuning, same(custom));
      expect(CursorMotionController(tuning: custom).tuning, same(custom));
    });

    test('copyWith overrides a single field, leaves others intact', () {
      // Production code paths (preset switching, debug knob nudges)
      // need a way to mutate one field without rewriting the whole
      // record.
      const t = MotionTuning.defaults;
      final faster = t.copyWith(cursorFeedforwardStrength: 0.9);

      expect(faster.cursorFeedforwardStrength, 0.9);
      expect(faster.cursorAtRestPxPerSec, t.cursorAtRestPxPerSec);
      expect(faster.dtCap, t.dtCap);
    });
  });
}
