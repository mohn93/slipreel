import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no committed lib/ source imports agent_wires_probe', () {
    final libDir = Directory('lib');
    final offenders = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue; // skips .template
      final text = entity.readAsStringSync();
      if (text.contains('package:agent_wires_probe')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'agent_wires_probe must stay optional; found imports in: '
          '$offenders',
    );
  });
}
