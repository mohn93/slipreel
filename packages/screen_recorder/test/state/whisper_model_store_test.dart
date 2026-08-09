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

  test('a verified model is trusted on later calls — no re-hash, no '
      're-download', () async {
    // Regression: ensureModel re-read and re-hashed the model on EVERY
    // call, including cache hits. At the real model's 487 MB that froze
    // the UI for seconds on every "Generate captions" click. Integrity
    // is now verified once (at download) and recorded in a marker;
    // later calls trust the marker.
    final bytes = [5, 5, 5];
    final sha = sha256.convert(bytes).toString();
    var downloads = 0;
    final store = WhisperModelStore(
      baseDir: tmp,
      expectedSha256: sha,
      downloader: (url, dest, onProgress) async {
        downloads++;
        await dest.writeAsBytes(bytes);
      },
    );

    final path = await store.ensureModel();
    expect(downloads, 1);

    // Corrupt the model body but keep the verification marker. A
    // trusted cache hit must NOT notice (we no longer pay a full read
    // to defend against on-disk corruption per call) — the old
    // implementation re-hashed, saw the mismatch, and re-downloaded.
    File(path).writeAsBytesSync([6, 6, 6]);
    final again = await store.ensureModel();
    expect(again, path);
    expect(downloads, 1,
        reason: 'a marked-verified model must be trusted without '
            're-reading it');
  });

  test('a pre-existing valid model without a marker is verified once and '
      'marked', () async {
    final bytes = [1, 2, 3, 4];
    File('${tmp.path}/$kWhisperModelFileName').writeAsBytesSync(bytes);
    final sha = sha256.convert(bytes).toString();

    var downloads = 0;
    final store = WhisperModelStore(
      baseDir: tmp,
      expectedSha256: sha,
      downloader: (_, __, ___) async => downloads++,
    );
    await store.ensureModel();
    expect(downloads, 0);
    expect(
      File('${tmp.path}/$kWhisperModelFileName.verified').existsSync(),
      isTrue,
      reason: 'migration for installs that predate the marker: one full '
          'verification, then the marker makes future calls cheap',
    );
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
    expect(File('${tmp.path}/$kWhisperModelFileName.part').existsSync(), isFalse);
  });
}
