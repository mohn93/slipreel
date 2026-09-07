import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';

void main() {
  test('clears restored mic on sentinel before user interaction', () {
    expect(
      shouldClearRestoredMic(hasSelection: true, userTouchedMic: false, level: -1),
      isTrue,
    );
  });
  test('does not clear once user touched the control', () {
    expect(
      shouldClearRestoredMic(hasSelection: true, userTouchedMic: true, level: -1),
      isFalse,
    );
  });
  test('does not clear on a normal level', () {
    expect(
      shouldClearRestoredMic(hasSelection: true, userTouchedMic: false, level: 0.3),
      isFalse,
    );
  });
  test('does nothing without a selection', () {
    expect(
      shouldClearRestoredMic(hasSelection: false, userTouchedMic: false, level: -1),
      isFalse,
    );
  });
}
