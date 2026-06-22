// packages/screen_recorder/test/state/whisper_model_store_test.dart
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/whisper_model_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('wms_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('returns cached path without downloading when file is valid', () async {
    final bytes = [1, 2, 3, 4];
    final modelFile = File('${tmp.path}/$kWhisperModelFileName')
      ..writeAsBytesSync(bytes);
    final sha = sha256.convert(bytes).toString();

    var called = false;
    final store = WhisperModelStore(
      baseDir: tmp,
      downloader: (_, __, ___) async => called = true,
      expectedSha256: sha,
    );
    final path = await store.ensureModel();
    expect(path, modelFile.path);
    expect(called, isFalse);
  });

  test('downloads + verifies + caches on a miss', () async {
    final bytes = [9, 8, 7];
    final sha = sha256.convert(bytes).toString();
    final store = WhisperModelStore(
      baseDir: tmp,
      expectedSha256: sha,
      downloader: (url, dest, onProgress) async {
        onProgress?.call(1.0);
        await dest.writeAsBytes(bytes);
      },
    );
    final path = await store.ensureModel();
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), bytes);
  });

  test('checksum mismatch deletes the partial and throws', () async {
    final store = WhisperModelStore(
      baseDir: tmp,
      expectedSha256: 'deadbeef',
      downloader: (url, dest, onProgress) async =>
          dest.writeAsBytes([0, 0, 0]),
    );
    await expectLater(store.ensureModel(), throwsA(isA<Exception>()));
    expect(File('${tmp.path}/$kWhisperModelFileName').existsSync(), isFalse);
  });
}
