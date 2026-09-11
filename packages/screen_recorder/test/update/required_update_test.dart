import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/update/required_update.dart';
import 'package:screen_recorder/update/required_update_dialog.dart';

String _item({
  int build = 1000020,
  String os = '13.0',
  String date = 'Fri, 11 Sep 2026 00:00:00 +0000',
}) =>
    '''
<item><sparkle:version>$build</sparkle:version>
<sparkle:shortVersionString>1.0.20</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>$os</sparkle:minimumSystemVersion>
<pubDate>$date</pubDate>
<enclosure url="https://slipreel.app/download/update.dmg" sparkle:edSignature="signature" />
</item>''';
String _feed({String minimum = '1000020', String? items}) =>
    '''
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<slipreelMinimumSupportedBuild>$minimum</slipreelMinimumSupportedBuild>
${items ?? _item()}
</channel></rss>''';

EntitlementLoaded _oneTime(DateTime until) => EntitlementLoaded(
  EntitlementClaims(
    sub: 'user',
    plan: 'onetime',
    exportEntitled: true,
    status: 'active',
    updatesUntil: until,
    deviceId: 'device',
    seatLimit: 2,
    issuedAt: DateTime.utc(2026),
    expiresAt: DateTime.utc(2027),
  ),
);

void main() {
  final now = DateTime.utc(2026, 9, 11);
  RequiredUpdate? parse(
    String feed, {
    int build = 1000019,
    String os = '13.0',
  }) => parseRequiredUpdate(feed, currentBuild: build, systemVersion: os);

  test('force policy applies below floor, not at or above it', () {
    expect(parse(_feed())?.build, 1000020);
    expect(parse(_feed(), build: 1000020), isNull);
    expect(parse(_feed(), build: 1000021), isNull);
    expect(parse(_feed(minimum: '0')), isNull);
    expect(parse(_feed(minimum: '')), isNull);
    expect(parse(_feed(minimum: 'bad')), isNull);
    expect(parse('<broken'), isNull);
    expect(
      parse(
        _feed().replaceAll(
          RegExp(
            r'<slipreelMinimumSupportedBuild>.*?</slipreelMinimumSupportedBuild>',
          ),
          '',
        ),
      ),
      isNull,
    );
  });

  test('requires an installable signed HTTPS target meeting the floor', () {
    expect(parse(_feed(minimum: '1000030')), isNull);
    expect(parse(_feed(), os: '12.6'), isNull);
    expect(
      parse(
        _feed(items: _item(os: '13.1')),
        os: '13.0.9',
      ),
      isNull,
    );
    expect(parse(_feed().replaceAll('https:', 'http:')), isNull);
    expect(
      parse(_feed().replaceAll('sparkle:edSignature="signature"', '')),
      isNull,
    );
    expect(parse(_feed(items: _item(date: 'bad'))), isNull);
  });

  test('selects highest compatible build regardless of feed ordering', () {
    final items =
        _item(build: 1000021) + _item() + _item(build: 1000022, os: '99.0');
    expect(parse(_feed(items: items))?.build, 1000021);
  });

  test(
    'free and covered users qualify; expired or uncovered licenses do not',
    () {
      final update = parse(_feed())!;
      expect(update.appliesTo(const EntitlementSignedOut(), now: now), isTrue);
      expect(update.appliesTo(const EntitlementLoading(), now: now), isFalse);
      expect(
        update.appliesTo(_oneTime(now.add(const Duration(days: 1))), now: now),
        isTrue,
      );
      expect(
        update.appliesTo(
          _oneTime(now.subtract(const Duration(seconds: 1))),
          now: now,
        ),
        isFalse,
      );
      final futureRelease = parse(
        _feed(items: _item(date: 'Sun, 13 Sep 2026 00:00:00 +0000')),
      )!;
      expect(
        futureRelease.appliesTo(
          _oneTime(now.add(const Duration(days: 1))),
          now: now,
        ),
        isFalse,
      );
    },
  );

  test('required-update provider exempts expired paid coverage', () {
    final container = ProviderContainer(
      overrides: [
        entitlementProvider.overrideWithValue(_oneTime(DateTime.utc(2020))),
      ],
    );
    addTearDown(container.dispose);
    container.read(requiredUpdateCandidateProvider.notifier).state = parse(
      _feed(),
    );
    expect(container.read(requiredUpdateProvider), isNull);
  });

  testWidgets(
    'required dialog cannot be dismissed and can retry updater failures',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => RequiredUpdateDialog(
                    update: parse(_feed())!,
                    onUpdate: () async {
                      attempts++;
                      if (attempts == 1) throw Exception('unavailable');
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not open the updater. Please try again.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Update required'), findsOneWidget);
      expect(
        find.text('Could not open the updater. Please try again.'),
        findsNothing,
      );
    },
  );
}
