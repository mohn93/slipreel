import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/update/updater_backend.dart';
import 'package:screen_recorder/update/updater_service.dart';

class _FakeBackend implements UpdaterBackend {
  final List<String> calls = [];
  String? feedUrl;
  int? interval;

  @override
  Future<void> setFeedURL(String url) async {
    feedUrl = url;
    calls.add('setFeedURL');
  }

  @override
  Future<void> setScheduledCheckInterval(int seconds) async {
    interval = seconds;
    calls.add('setScheduledCheckInterval');
  }

  @override
  Future<void> checkForUpdates() async => calls.add('checkForUpdates');
}

void main() {
  test('init sets the feed URL and the daily interval, and is idempotent',
      () async {
    final backend = _FakeBackend();
    final service = UpdaterService(backend);

    await service.init();
    await service.init(); // second call must not re-configure

    expect(backend.feedUrl,
        'https://slipreel.app/appcast.xml');
    expect(backend.interval, 86400);
    expect(backend.calls.where((c) => c == 'setFeedURL').length, 1);
  });

  test('checkForUpdates delegates to the backend', () async {
    final backend = _FakeBackend();
    final service = UpdaterService(backend);

    await service.checkForUpdates();

    expect(backend.calls, contains('checkForUpdates'));
  });
}
