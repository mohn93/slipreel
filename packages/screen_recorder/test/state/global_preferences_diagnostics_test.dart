import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';

void main() {
  test('defaults shareDiagnostics to true', () {
    expect(const GlobalPreferences().shareDiagnostics, isTrue);
  });

  test('absent in JSON means on (existing users keep default)', () {
    final p = GlobalPreferences.fromJson({'shareAnalytics': false});
    expect(p.shareDiagnostics, isTrue);
    expect(p.shareAnalytics, isFalse);
  });

  test('round-trips through JSON', () {
    final p = const GlobalPreferences().copyWith(shareDiagnostics: false);
    expect(GlobalPreferences.fromJson(p.toJson()).shareDiagnostics, isFalse);
  });
}
