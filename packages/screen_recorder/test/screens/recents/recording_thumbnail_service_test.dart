@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/recents/recording_thumbnail_service.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('thumb_svc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  RecordingHistoryEntry entryFor(String mp4) => RecordingHistoryEntry(
        videoPath: mp4,
        recordedAt: DateTime.utc(2026, 5, 14),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );

  test('generates when thumb missing, then caches (no regen on 2nd call)', () async {
    final mp4 = '${tmp.path}/r.mp4';
    File(mp4).writeAsBytesSync([0]); // file must exist
    var gen = 0;
    final svc = RecordingThumbnailService(
      probeDuration: (_) async => const Duration(seconds: 10),
      generate: (entry, at, out) async {
        gen++;
        out.writeAsBytesSync([1, 2, 3]); // fake png
      },
    );

    final t1 = await svc.thumbFor(entryFor(mp4));
    expect(gen, 1);
    expect(t1.pngFile.path, '$mp4.thumb.png');
    expect(t1.duration, const Duration(seconds: 10));

    // 2nd call: png exists, no editor.json → not stale → no regen.
    svc.clearMemoryCache(); // force the disk-cache path, not the memo
    final t2 = await svc.thumbFor(entryFor(mp4));
    expect(gen, 1, reason: 'cached png is reused');
    expect(t2.pngFile.existsSync(), isTrue);
  });

  test('regenerates when editor.json is newer than the thumb', () async {
    final mp4 = '${tmp.path}/r.mp4';
    File(mp4).writeAsBytesSync([0]);
    final thumb = File('$mp4.thumb.png')..writeAsBytesSync([9]);
    final editor = File('$mp4.editor.json')..writeAsStringSync('{}');
    // Make editor.json strictly newer than the thumb.
    final future = DateTime.now().add(const Duration(seconds: 5));
    editor.setLastModifiedSync(future);
    thumb.setLastModifiedSync(DateTime.now().subtract(const Duration(seconds: 5)));

    var gen = 0;
    final svc = RecordingThumbnailService(
      probeDuration: (_) async => const Duration(seconds: 10),
      generate: (e, at, out) async { gen++; out.writeAsBytesSync([1]); },
    );
    await svc.thumbFor(entryFor(mp4));
    expect(gen, 1, reason: 'editor.json newer than thumb → regenerate');
  });

  test('backfills meta.json durationMs when meta lacks it', () async {
    final mp4 = '${tmp.path}/r.mp4';
    File(mp4).writeAsBytesSync([0]);
    // v1 meta (no durationMs).
    await RecordingMetadata(
      isPureSource: true, recordedAt: DateTime.utc(2026), widthPx: 1920,
      heightPx: 1080, fps: 60,
    ).saveForVideo(mp4); // duration null → no durationMs key

    final svc = RecordingThumbnailService(
      probeDuration: (_) async => const Duration(milliseconds: 12345),
      generate: (e, at, out) async => out.writeAsBytesSync([1]),
    );
    await svc.thumbFor(entryFor(mp4));

    final reloaded = await RecordingMetadata.loadForVideo(mp4);
    expect(reloaded.duration, const Duration(milliseconds: 12345),
        reason: 'probed duration is written back into meta.json');
  });

  test('missing video file throws RecordingMissingException', () async {
    final svc = RecordingThumbnailService(
      probeDuration: (_) async => null,
      generate: (e, at, out) async {},
    );
    await expectLater(
      svc.thumbFor(entryFor('${tmp.path}/gone.mp4')),
      throwsA(isA<RecordingMissingException>()),
    );
  });
}
