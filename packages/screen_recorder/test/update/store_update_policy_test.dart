import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/update/store_update_policy.dart';

void main() {
  const published = <String, Object?>{
    'store_update_available': true,
    'store_latest_build': '10108',
    'store_minimum_build': '10100',
    'store_latest_version': '1.1.0',
  };
  test('offers a dismissible update above the minimum', () {
    expect(StoreUpdatePolicy.parse(published, 10107)?.required, false);
  });
  test('requires an update only below the minimum', () {
    expect(StoreUpdatePolicy.parse(published, 10099)?.required, true);
    expect(StoreUpdatePolicy.parse(published, 10100)?.required, false);
  });
  test('current and newer TestFlight builds are not gated', () {
    expect(StoreUpdatePolicy.parse(published, 10108), isNull);
    expect(StoreUpdatePolicy.parse(published, 10109), isNull);
  });
  test('unpublished, malformed, and impossible policies fail open', () {
    for (final override in <Map<String, Object?>>[
      {'store_update_available': false},
      {'store_minimum_build': '10109'},
      {'store_minimum_build': '-1'},
      {'store_latest_build': 'oops'},
      {'store_latest_version': 'invalid'},
    ]) {
      expect(
        StoreUpdatePolicy.parse({...published, ...override}, 10099),
        isNull,
      );
    }
    expect(StoreUpdatePolicy.parse(published, 0), isNull);
    expect(StoreUpdatePolicy.parse({}, 10099), isNull);
  });
}
