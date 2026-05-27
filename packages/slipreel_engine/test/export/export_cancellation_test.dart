import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';

void main() {
  group('CancelToken', () {
    test('starts not cancelled', () {
      expect(CancelToken().isCancelled, isFalse);
    });

    test('cancel() flips isCancelled and completes whenCancelled', () async {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(token.isCancelled, isTrue);
      await token.whenCancelled;
    });

    test('cancel() is idempotent', () {
      final token = CancelToken()..cancel();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });
  });
}
