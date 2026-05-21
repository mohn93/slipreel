@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `slipreel_engine` package must not import anything from the
/// `screen_recorder` shell. That direction defeats the entire reason
/// the engine was extracted: a headless CLI exporter, a plugin SDK,
/// or a cloud worker that depends on `slipreel_engine` alone cannot
/// drag the editor's Flutter widget tree along.
///
/// Phase 1 of P0-3 fixed an in-package version of this (engine dirs
/// inside screen_recorder reaching into lib/ui/). Phase 2 split the
/// engine into this sibling package, so the boundary now lives at
/// the package level — this test enforces it from inside the engine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('slipreel_engine has no import of package:screen_recorder/*',
      () async {
    final violations = <String>[];
    final importRe = RegExp(
      r'''import\s+['"]package:screen_recorder/[^'"]+['"]''',
    );

    final libDir = Directory('lib');
    if (await libDir.exists()) {
      await for (final entity
          in libDir.list(recursive: true, followLinks: false)) {
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
      reason: 'slipreel_engine is the headless engine package — it must '
          'not import from the screen_recorder shell. Either move the '
          'imported code into slipreel_engine, or invert the dependency '
          'so the shell owns the integration. Violations:\n'
          '${violations.join('\n')}',
    );
  });
}
