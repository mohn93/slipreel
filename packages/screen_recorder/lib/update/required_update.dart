import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xml/xml.dart';

import '../licensing/entitlement.dart';
import '../licensing/licensing_controller.dart';
import 'update_eligibility.dart';

class RequiredUpdate {
  const RequiredUpdate({
    required this.build,
    required this.version,
    required this.releaseDate,
  });
  final int build;
  final String version;
  final DateTime releaseDate;

  bool appliesTo(EntitlementState state, {DateTime? now}) {
    if (!canOfferAutomaticUpdate(state, now: now)) return false;
    if (state is EntitlementLoaded && state.claims.plan == 'onetime') {
      return !releaseDate.isAfter(state.claims.updatesUntil!);
    }
    return true;
  }
}

final requiredUpdateCandidateProvider = StateProvider<RequiredUpdate?>(
  (ref) => null,
);
final requiredUpdateProvider = Provider<RequiredUpdate?>((ref) {
  final candidate = ref.watch(requiredUpdateCandidateProvider);
  if (candidate == null) return null;
  return candidate.appliesTo(ref.watch(entitlementProvider)) ? candidate : null;
});

/// An unavailable/malformed feed never creates a lockout. Sparkle still owns
/// artifact signature verification and installation; this only reads policy.
Future<RequiredUpdate?> fetchRequiredUpdate(String feedUrl) async {
  final client = http.Client();
  try {
    final response = await client
        .get(Uri.parse(feedUrl))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 2 * 1024 * 1024) {
      return null;
    }
    final package = await PackageInfo.fromPlatform();
    final build = int.tryParse(package.buildNumber);
    if (build == null) return null;
    final os = await Process.run('/usr/bin/sw_vers', [
      '-productVersion',
    ]).timeout(const Duration(seconds: 2));
    if (os.exitCode != 0) return null;
    return parseRequiredUpdate(
      response.body,
      currentBuild: build,
      systemVersion: (os.stdout as String).trim(),
    );
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

const _sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

/// The policy lives on the channel and survives ordinary release publication.
/// Only enforce when an installable, newer release satisfies the minimum.
RequiredUpdate? parseRequiredUpdate(
  String source, {
  required int currentBuild,
  required String systemVersion,
}) {
  try {
    final channel = XmlDocument.parse(source).rootElement.getElement('channel');
    if (channel == null) return null;
    final minimum = int.tryParse(
      channel.getElement('slipreelMinimumSupportedBuild')?.innerText.trim() ??
          '',
    );
    if (minimum == null || minimum <= 0 || currentBuild >= minimum) return null;
    RequiredUpdate? latest;
    for (final item in channel.findElements('item')) {
      String? field(String name) =>
          item.getElement(name, namespace: _sparkle)?.innerText.trim();
      final build = int.tryParse(field('version') ?? '');
      final version = field('shortVersionString');
      final url = Uri.tryParse(
        item.getElement('enclosure')?.getAttribute('url') ?? '',
      );
      if (build == null ||
          build < minimum ||
          build <= currentBuild ||
          version == null ||
          version.isEmpty ||
          url?.scheme != 'https' ||
          url!.host.isEmpty) {
        continue;
      }
      // Do not block users whose OS cannot install the required release.
      final minOS = field('minimumSystemVersion');
      final maxOS = field('maximumSystemVersion');
      if (minOS != null && _compareVersions(systemVersion, minOS) < 0) continue;
      if (maxOS != null && _compareVersions(systemVersion, maxOS) > 0) continue;
      final minimumUpdate = int.tryParse(field('minimumUpdateVersion') ?? '0');
      if (minimumUpdate == null || currentBuild < minimumUpdate) continue;
      if (item
              .getElement('enclosure')
              ?.getAttribute('edSignature', namespace: _sparkle)
              ?.isNotEmpty !=
          true) {
        continue;
      }
      final date = HttpDate.parse(
        item
            .getElement('pubDate')!
            .innerText
            .trim()
            .replaceFirst(RegExp(r' \+0000$'), ' GMT'),
      ).toUtc();
      if (latest == null || build > latest.build) {
        latest = RequiredUpdate(
          build: build,
          version: version,
          releaseDate: date,
        );
      }
    }
    return latest;
  } catch (_) {
    return null;
  }
}

int _compareVersions(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var i = 0; i < a.length || i < b.length; i++) {
    final difference = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (difference != 0) return difference;
  }
  return 0;
}
