import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no tracked lib/ source imports agent_wires_probe', () {
    // Scan only git-tracked files so a developer who follows the local
    // opt-in (copying the gitignored `agent_wires_probe_binding.dart`) does
    // not get a false failure. The guard is about *committed* sources.
    final result = Process.runSync(
      'git',
      ['ls-files', 'lib/*.dart', 'lib/**/*.dart'],
      workingDirectory: Directory.current.path,
    );
    final files = (result.stdout as String)
        .split('\n')
        .where((l) => l.trim().isNotEmpty);
    final offenders = <String>[];
    for (final path in files) {
      final text = File(path).readAsStringSync();
      if (text.contains('package:agent_wires_probe')) offenders.add(path);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'agent_wires_probe must stay optional; found in: $offenders',
    );
  });
}
