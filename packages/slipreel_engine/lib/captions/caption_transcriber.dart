import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slipreel_engine/captions/whisper_resolver.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

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

  Future<List<CaptionSegment>> transcribe({
    required String audioPath,
    required String modelPath,
    String language = 'auto',
    String? outBase,
  }) async {
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
    final result = await Process.run(bin, args);
    if (result.exitCode != 0) {
      throw Exception('whisper-cli exited ${result.exitCode}: '
          '${(result.stderr as String?)?.trim() ?? ''}');
    }
    final jsonFile = File('$base.json');
    if (!jsonFile.existsSync()) {
      throw Exception('whisper-cli produced no JSON at ${jsonFile.path}');
    }
    return parseWhisperJson(await jsonFile.readAsString());
  }
}
