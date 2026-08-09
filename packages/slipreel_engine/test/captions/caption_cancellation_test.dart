import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

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
}
