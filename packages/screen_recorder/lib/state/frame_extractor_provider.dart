import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

/// Identifies a single extracted frame: the source video, the timestamp, and
/// the target pixel size. A value type so [frameExtractorProvider]'s family
/// de-dupes by content while the inspector is open.
@immutable
class FrameKey {
  const FrameKey(this.videoPath, this.atMicros, this.width, this.height);

  final String videoPath;
  final int atMicros;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is FrameKey &&
      other.videoPath == videoPath &&
      other.atMicros == atMicros &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(videoPath, atMicros, width, height);
}

/// Decodes a single video frame at [FrameKey.atMicros], scaled to the key's
/// target size, as a [ui.Image]. In-memory only (`autoDispose`): the frame is
/// freed when the zoom region is deselected. Returns null on any failure
/// (ffmpeg missing, bad path, decode error) so callers fall back to a plain
/// background.
final frameExtractorProvider =
    FutureProvider.autoDispose.family<ui.Image?, FrameKey>((ref, key) async {
  final bytes = await _extractFrameRgba(key);
  if (bytes == null) return null;
  return decodeRgbaToImage(bytes, key.width, key.height);
});

/// Runs ffmpeg to grab one RGBA frame scaled to [FrameKey.width]×[height].
/// Returns null (never throws) when ffmpeg is unavailable or the output is
/// short/empty.
///
/// Extracts and decodes as `rgba`/`rgba8888` consistently — note the existing
/// recording-thumbnail extractor pulls `bgra` then decodes `rgba8888` (a
/// red/blue channel swap); this path deliberately does not.
Future<Uint8List?> _extractFrameRgba(FrameKey key) async {
  if (key.width <= 0 || key.height <= 0) return null;
  try {
    final seconds = (key.atMicros / 1e6).toStringAsFixed(3);
    final result = await Process.run(
      Ffmpeg.resolve(),
      <String>[
        '-loglevel', 'error',
        '-ss', seconds,
        '-i', key.videoPath,
        '-frames:v', '1',
        '-vf', 'scale=${key.width}:${key.height}',
        '-f', 'rawvideo',
        '-pix_fmt', 'rgba',
        '-',
      ],
      stdoutEncoding: null,
    );
    final out = result.stdout as List<int>;
    final expected = key.width * key.height * 4;
    if (out.length < expected) return null;
    return Uint8List.fromList(out.sublist(0, expected));
  } catch (_) {
    return null;
  }
}

/// Builds a [ui.Image] from tightly-packed RGBA bytes. Top-level (not private)
/// so it can be unit-tested without invoking ffmpeg.
Future<ui.Image> decodeRgbaToImage(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
