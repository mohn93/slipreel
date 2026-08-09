import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slipreel_engine/captions/whisper_resolver.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

/// Thrown by the caption toolchain when its [CancelToken] fires — either
/// before a stage starts or while its subprocess is running (the process
/// is SIGKILLed). Callers surface this as "cancelled", not an error.
class CaptionCancelledException implements Exception {
  const CaptionCancelledException();

  @override
  String toString() => 'CaptionCancelledException';
}

/// Parses whisper.cpp `-oj` (output-json) text into caption segments.
///
/// The JSON shape is `{ "transcription": [ { "offsets": {"from": ms, "to": ms},
/// "text": "..." }, ... ] }`. Defensive: unknown shapes / parse errors yield an
/// empty list, whitespace-only segments are dropped, text is trimmed.
List<CaptionSegment> parseWhisperJson(String jsonText) {
  Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map<String, dynamic>) return const [];
  final raw = decoded['transcription'];
  if (raw is! List) return const [];

  final out = <CaptionSegment>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map<String, dynamic>) continue;
    final offsets = item['offsets'];
    if (offsets is! Map<String, dynamic>) continue;
    final fromMs = offsets['from'] is num ? (offsets['from'] as num).toInt() : null;
    final toMs = offsets['to'] is num ? (offsets['to'] as num).toInt() : null;
    final text = item['text'] is String ? (item['text'] as String).trim() : '';
    if (fromMs == null || toMs == null || text.isEmpty) continue;
    out.add(CaptionSegment(
      id: 'seg_$i',
      startMicros: fromMs * 1000,
      endMicros: toMs * 1000,
      text: text,
    ));
  }
  return out;
}

/// Returns [segments] with every timestamp shifted later by [offsetMicros].
///
/// whisper times are relative to the start of the extracted WAV, which drops
/// the recording's audio leading-gap (see `captionAudioOffsetMicros`). Adding
/// the gap maps them onto movie-time so captions line up with the audio in the
/// preview and export. Returns the input unchanged when [offsetMicros] is 0.
List<CaptionSegment> shiftCaptionSegments(
  List<CaptionSegment> segments,
  int offsetMicros,
) {
  if (offsetMicros == 0) return segments;
  return [
    for (final s in segments)
      s.copyWith(
        startMicros: s.startMicros + offsetMicros,
        endMicros: s.endMicros + offsetMicros,
      ),
  ];
}

/// Runs `whisper-cli` on a WAV and returns the parsed caption segments.
class CaptionTranscriber {
  const CaptionTranscriber();

  /// [cancelToken]: transcription of a long recording runs for minutes;
  /// firing the token SIGKILLs the whisper subprocess and throws
  /// [CaptionCancelledException] instead of leaving an orphan pinning a
  /// CPU core (the old Process.run was unkillable).
  Future<List<CaptionSegment>> transcribe({
    required String audioPath,
    required String modelPath,
    String language = 'auto',
    String? outBase,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const CaptionCancelledException();
    }
    final base = outBase ??
        p.join(p.dirname(audioPath), 'caption_transcript');
    final String bin;
    try {
      bin = Whisper.resolve();
    } on WhisperNotFoundException {
      throw Exception(
          'whisper-cli not found. Install it with: brew install whisper-cpp');
    }
    final args = <String>[
      '-m', modelPath,
      '-f', audioPath,
      '-l', language,
      '-oj',
      '-of', base,
      '--no-prints',
    ];
    final process = await Process.start(bin, args);
    cancelToken?.whenCancelled
        .then((_) => process.kill(ProcessSignal.sigkill));
    final stderrText =
        process.stderr.transform(const SystemEncoding().decoder).join();
    unawaited(process.stdout.drain<void>());
    final exitCode = await process.exitCode;
    if (cancelToken?.isCancelled ?? false) {
      throw const CaptionCancelledException();
    }
    if (exitCode != 0) {
      throw Exception(
          'whisper-cli exited $exitCode: ${(await stderrText).trim()}');
    }
    final jsonFile = File('$base.json');
    if (!jsonFile.existsSync()) {
      throw Exception('whisper-cli produced no JSON at ${jsonFile.path}');
    }
    return parseWhisperJson(await jsonFile.readAsString());
  }
}
