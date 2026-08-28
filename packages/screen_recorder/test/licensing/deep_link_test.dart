import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/deep_link.dart';

void main() {
  test('parses a well-formed slipreel://auth link', () {
    final uri = Uri.parse(
        'slipreel://auth?token=jwt.abc&refresh=rt_1&device_id=dev_2&state=n0nce');
    final link = AuthDeepLink.parse(uri);
    expect(link, isNotNull);
    expect(link!.token, 'jwt.abc');
    expect(link.refresh, 'rt_1');
    expect(link.deviceId, 'dev_2');
    expect(link.state, 'n0nce');
  });

  test('rejects wrong host', () {
    final uri = Uri.parse('slipreel://other?token=a&refresh=b&device_id=c&state=d');
    expect(AuthDeepLink.parse(uri), isNull);
  });

  test('rejects wrong scheme', () {
    final uri = Uri.parse('https://auth?token=a&refresh=b&device_id=c&state=d');
    expect(AuthDeepLink.parse(uri), isNull);
  });

  test('rejects when a param is missing', () {
    final uri = Uri.parse('slipreel://auth?token=a&refresh=b&device_id=c');
    expect(AuthDeepLink.parse(uri), isNull);
  });

  test('rejects when a param is empty', () {
    final uri =
        Uri.parse('slipreel://auth?token=&refresh=b&device_id=c&state=d');
    expect(AuthDeepLink.parse(uri), isNull);
  });
}
