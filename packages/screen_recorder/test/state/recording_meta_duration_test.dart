@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('record-stop writes duration into the RecordingMetadata sidecar', () {
    final src = File('lib/state/recording_state.dart').readAsStringSync();
    final ctorStart = src.indexOf('RecordingMetadata(');
    expect(ctorStart, greaterThanOrEqualTo(0));
    final ctorEnd = src.indexOf(')', ctorStart);
    final ctor = src.substring(ctorStart, ctorEnd);
    expect(ctor.contains('duration:'), isTrue,
        reason: 'the meta sidecar saved at record-stop must persist the '
            'recording duration so Recents can show it without probing');
  });
}
