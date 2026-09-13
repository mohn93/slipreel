import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/distribution/distribution_channel.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/update/required_update.dart';
import 'package:screen_recorder/update/updater_backend.dart';
import 'package:screen_recorder/update/updater_service.dart';

class _ForbiddenSparkle implements UpdaterBackend {
  @override
  Future<void> setFeedURL(String url) async =>
      fail('Store initialized appcast');
  @override
  Future<void> setScheduledCheckInterval(int seconds) async =>
      fail('Store scheduled Sparkle');
  @override
  Future<void> checkForUpdates({bool inBackground = false}) async =>
      fail('Store invoked Sparkle');
}

void main() {
  test(
    'Store update paths never load appcast or invoke Sparkle',
    () async {
      final service = UpdaterService(
        _ForbiddenSparkle(),
        loadRequiredUpdate: () async {
          fail('Store loaded appcast');
        },
      );
      await service.init();
      expect(
        await service.checkAtStartup(() => const EntitlementSignedOut()),
        isNull,
      );
      await service.checkForUpdates();
      expect(await fetchRequiredUpdate('invalid://must-never-fetch'), isNull);
    },
    skip: !DistributionChannel.isAppStore,
  );
}
