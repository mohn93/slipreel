import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/export_telemetry_store.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('exp_telemetry');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String tmpPath() => '${tmp.path}/export_telemetry.json';

  test('load returns null when file is missing', () async {
    final store = ExportTelemetryStore(filePath: tmpPath());
    expect(await store.loadRealtimeMultiplier(), isNull);
  });

  test('save then load round-trips the multiplier', () async {
    final store = ExportTelemetryStore(filePath: tmpPath());
    await store.saveRealtimeMultiplier(1.42);
    expect(await store.loadRealtimeMultiplier(), 1.42);
  });

  test('load returns null on corrupt JSON', () async {
    final path = tmpPath();
    await File(path).writeAsString('not json{{');
    final store = ExportTelemetryStore(filePath: path);
    expect(await store.loadRealtimeMultiplier(), isNull);
  });

  test('load throws FormatException on future schema version', () async {
    final path = tmpPath();
    await File(path).writeAsString(jsonEncode({
      'schemaVersion': 99,
      'normalizedRealtimeMultiplier': 1.0,
    }));
    final store = ExportTelemetryStore(filePath: path);
    await expectLater(store.loadRealtimeMultiplier(), throwsFormatException);
  });

  test('load returns null when schemaVersion is missing', () async {
    final path = tmpPath();
    await File(path).writeAsString(
      jsonEncode({'normalizedRealtimeMultiplier': 1.0}),
    );
    final store = ExportTelemetryStore(filePath: path);
    expect(await store.loadRealtimeMultiplier(), isNull);
  });

  test('load returns null when value is non-positive', () async {
    final path = tmpPath();
    await File(path).writeAsString(jsonEncode({
      'schemaVersion': 1,
      'normalizedRealtimeMultiplier': 0.0,
    }));
    final store = ExportTelemetryStore(filePath: path);
    expect(await store.loadRealtimeMultiplier(), isNull);
  });

  test('concurrent saves are serialized', () async {
    final store = ExportTelemetryStore(filePath: tmpPath());
    final order = <int>[];
    final futures = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      futures.add(
        store.saveRealtimeMultiplier(0.1 * (i + 1)).then((_) => order.add(i)),
      );
    }
    await Future.wait(futures);
    expect(order, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  test('save cleans up tmp file on success', () async {
    final path = tmpPath();
    final store = ExportTelemetryStore(filePath: path);
    await store.saveRealtimeMultiplier(0.9);
    expect(File('$path.tmp').existsSync(), isFalse);
    expect(File(path).existsSync(), isTrue);
  });
}
