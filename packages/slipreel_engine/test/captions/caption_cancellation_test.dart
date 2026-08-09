import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

/// The `slipreel_caption_*` temp dirs currently in the system temp dir.
Set<String> _captionTempDirs() => Directory.systemTemp
    .listSync()
    .whereType<Directory>()
    .map((d) => d.path)
    .where((p) => p.split(Platform.pathSeparator).last
        .startsWith('slipreel_caption_'))
    .toSet();

/// Cancellation contract for the caption toolchain: both stages accept a
/// [CancelToken] and refuse to (keep) running once it fires. The entry
/// check is what these tests pin headlessly; the kill-the-live-process
/// wiring shares the same token.
void main() {
  test('transcriber throws CaptionCancelledException on a cancelled token '
      'before touching whisper', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      const CaptionTranscriber().transcribe(
        audioPath: '/nonexistent.wav',
        modelPath: '/nonexistent.bin',
        cancelToken: token,
      ),
      throwsA(isA<CaptionCancelledException>()),
    );
  });

  test('extractor throws CaptionCancelledException on a cancelled token '
      'before probing', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      const CaptionAudioExtractor().extract(
        '/nonexistent.mp4',
        CaptionAudioSource.mic,
        cancelToken: token,
      ),
      throwsA(isA<CaptionCancelledException>()),
    );
  });

  test('cancelling extraction mid-run cleans up the temp dir it created',
      () async {
    // Regression: the extractor mints a slipreel_caption_* temp dir after
    // probing, then may throw (cancel) or return null (ffmpeg failure)
    // without a path — the controller only reaps dirs whose WAV path it
    // received, so those leaked. Cancel lands after extract()'s entry
    // check (its first await is the probe) but before Process.start, so
    // this deterministically exercises the create-then-throw path.
    final fixture = File('test/fixtures/sample_recording.mp4');
    if (!fixture.existsSync()) {
      markTestSkipped('fixture missing');
      return;
    }
    final probe = await ffmpegProbe(path: fixture.path);
    if (probe.audioStreams.isEmpty) {
      markTestSkipped('fixture has no audio to extract');
      return;
    }

    final before = _captionTempDirs();
    final token = CancelToken();
    final future = const CaptionAudioExtractor()
        .extract(fixture.path, CaptionAudioSource.mic, cancelToken: token);
    token.cancel();
    await expectLater(future, throwsA(isA<CaptionCancelledException>()));

    expect(_captionTempDirs().difference(before), isEmpty,
        reason: 'a cancelled extraction must delete the temp dir it created');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
