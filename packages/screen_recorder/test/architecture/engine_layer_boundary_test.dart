@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Engine layer = anything under these top-level lib/ subdirectories.
/// These directories must compile without Flutter widget-tree code so
/// they can move into a sibling `slipreel_engine` package, drive
/// headless CLI exports, or be loaded by plugin SDKs.
const _engineDirs = <String>[
  'lib/models',
  'lib/rendering',
  'lib/effects',
  'lib/export',
  'lib/state',
];

/// Importing widget-tier code from the engine layer is a silent
/// architectural regression — it's how export came to depend on
/// CustomPainter classes living under ui/widgets and how the
/// rendering layer ended up reaching into ui/widgets/zoom/ for
/// stateful spring controllers (both were fixed in P0-3).
///
/// This test scans engine-layer .dart files and fails if any imports
/// reach into `package:screen_recorder/ui/`. Adding a new
/// dependency-the-wrong-way will turn the build red on CI — no
/// silent recurrence.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('engine-layer Dart files do not import package:screen_recorder/ui/',
      () async {
    final violations = <String>[];
    final importRe = RegExp(
      r'''import\s+['"]package:screen_recorder/ui/[^'"]+['"]''',
    );

    for (final dirPath in _engineDirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;
        final content = await entity.readAsString();
        for (final line in content.split('\n')) {
          final match = importRe.firstMatch(line);
          if (match != null) {
            violations.add('${entity.path}: ${match.group(0)}');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Engine-layer files (models/, rendering/, effects/, export/, '
          'state/) must not import from lib/ui/. Either move the imported '
          "code into the engine layer, or invert the dependency so the UI "
          'layer owns the integration. Violations:\n'
          '${violations.join('\n')}',
    );
  });
}
