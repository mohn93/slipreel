import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/safe_export_output.dart';

void main() {
  late Directory dir;
  late File source;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('safe-export-test-');
    source = await File('${dir.path}/source.mp4').writeAsString('original');
  });
  tearDown(() async => dir.delete(recursive: true));
  test(
    'rejects source and symlink destinations without touching media',
    () async {
      await Link('${dir.path}/alias.mp4').create(source.path);
      for (final path in [source.path, '${dir.path}/alias.mp4']) {
        await expectLater(
          SafeExportOutput.create(path, [source.path]),
          throwsArgumentError,
        );
      }
      expect(await source.readAsString(), 'original');
    },
  );
  test('rejects hard-linked destination', () async {
    final alias = '${dir.path}/hardlink.mp4';
    final result = await Process.run('ln', [source.path, alias]);
    expect(result.exitCode, 0);
    await expectLater(
      SafeExportOutput.create(alias, [source.path]),
      throwsArgumentError,
    );
    expect(await source.readAsString(), 'original');
  });
  test('failure cleanup preserves previous destination', () async {
    final destination = await File(
      '${dir.path}/export.mp4',
    ).writeAsString('previous');
    final staged = await SafeExportOutput.create(destination.path, [
      source.path,
    ]);
    await File(staged.path).writeAsString('incomplete');
    await staged.dispose();
    expect(await destination.readAsString(), 'previous');
    expect(await source.readAsString(), 'original');
  });
  test(
    'publication replaces only destination and removes owned staging',
    () async {
      final destination = await File(
        '${dir.path}/export.mp4',
      ).writeAsString('previous');
      final staged = await SafeExportOutput.create(destination.path, [
        source.path,
      ]);
      await File(staged.path).writeAsString('complete');
      await staged.publish();
      await staged.dispose();
      expect(await destination.readAsString(), 'complete');
      expect(await source.readAsString(), 'original');
      expect(await staged.directory.exists(), isFalse);
    },
  );
}
