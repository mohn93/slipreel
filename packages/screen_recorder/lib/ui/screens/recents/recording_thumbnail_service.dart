import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show Size;
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';

import 'thumbnail_timestamp.dart';

/// Injectable seam: probes the duration of a video file.
typedef ProbeDuration = Future<Duration?> Function(String videoPath);

/// Injectable seam: generates a styled thumbnail PNG and writes it to [outPng].
typedef GenerateThumbPng = Future<void> Function(
    RecordingHistoryEntry entry, Duration at, File outPng);

/// Thrown when the video file referenced by a [RecordingHistoryEntry] no
/// longer exists on disk.
class RecordingMissingException implements Exception {
  RecordingMissingException(this.videoPath);
  final String videoPath;
  @override
  String toString() => 'RecordingMissingException($videoPath)';
}

/// A resolved thumbnail: a PNG file on disk and the recording's duration
/// (null when the duration could not be determined).
class RecordingThumbnail {
  const RecordingThumbnail({required this.pngFile, required this.duration});
  final File pngFile;
  final Duration? duration;
}

/// Lazily generates a styled thumbnail per recording, caches it to
/// `<videoPath>.thumb.png`, and regenerates when `<videoPath>.editor.json`
/// is newer than the cached PNG.
///
/// Duration is resolved from `meta.json`; if absent it is probed via
/// [ProbeDuration] and **backfilled** into the sidecar.
///
/// Heavy operations (ffprobe, frame-decode + composite + encode) are
/// injectable seams ([probeDuration], [generate]) so unit tests can run
/// without spawning ffmpeg.
class RecordingThumbnailService {
  RecordingThumbnailService({
    ProbeDuration? probeDuration,
    GenerateThumbPng? generate,
    this.maxConcurrent = 3,
  })  : _probeDuration = probeDuration ?? _defaultProbeDuration,
        _generate = generate ?? _defaultGenerate;

  final ProbeDuration _probeDuration;
  final GenerateThumbPng _generate;
  final int maxConcurrent;

  final Map<String, RecordingThumbnail> _memo = {};
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  /// Clears the in-memory memo cache so the next call exercises the
  /// disk-cache path rather than the already-resolved result.
  void clearMemoryCache() => _memo.clear();

  /// Returns a [RecordingThumbnail] for [entry], generating (and caching)
  /// the PNG if necessary.
  ///
  /// Throws [RecordingMissingException] if the video file does not exist.
  Future<RecordingThumbnail> thumbFor(RecordingHistoryEntry entry) async {
    final cached = _memo[entry.videoPath];
    if (cached != null) return cached;

    if (!File(entry.videoPath).existsSync()) {
      throw RecordingMissingException(entry.videoPath);
    }

    // ── 1. Resolve duration: meta.json → probe → backfill ───────────────
    final meta = await RecordingMetadata.loadForVideo(entry.videoPath);
    Duration? duration = meta.duration;
    if (duration == null) {
      duration = await _probeDuration(entry.videoPath);
      if (duration != null) {
        // Backfill: write the probed duration into the sidecar (v2).
        await RecordingMetadata(
          isPureSource: meta.isPureSource,
          recordedAt: meta.recordedAt,
          widthPx: meta.widthPx != 0 ? meta.widthPx : entry.widthPx,
          heightPx: meta.heightPx != 0 ? meta.heightPx : entry.heightPx,
          fps: meta.fps != 0 ? meta.fps : entry.fps,
          duration: duration,
        ).saveForVideo(entry.videoPath);
      }
    }

    // ── 2. Generate thumb if stale ───────────────────────────────────────
    final thumb = File('${entry.videoPath}.thumb.png');
    if (_isStale(entry.videoPath, thumb)) {
      await _runGuarded(() =>
          _generate(entry, thumbTimestamp(duration ?? Duration.zero), thumb));
    }

    final result = RecordingThumbnail(pngFile: thumb, duration: duration);
    _memo[entry.videoPath] = result;
    return result;
  }

  bool _isStale(String videoPath, File thumb) {
    if (!thumb.existsSync()) return true;
    final editor = File('$videoPath.editor.json');
    if (editor.existsSync() &&
        editor.lastModifiedSync().isAfter(thumb.lastModifiedSync())) {
      return true;
    }
    return false;
  }

  Future<void> _runGuarded(Future<void> Function() op) async {
    while (_active >= maxConcurrent) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;
    try {
      await op();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }

  // ── Default real seams (never called by unit tests) ───────────────────

  static Future<Duration?> _defaultProbeDuration(String videoPath) async {
    try {
      final r = await ffmpegProbe(path: videoPath);
      final sec = r.durationSec;
      return sec == null ? null : Duration(microseconds: (sec * 1e6).round());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _defaultGenerate(
      RecordingHistoryEntry entry, Duration at, File outPng) async {
    final videoSize =
        Size(entry.widthPx.toDouble(), entry.heightPx.toDouble());
    final w = entry.widthPx, h = entry.heightPx;

    // 1) Decode one BGRA frame at [at].
    final bgra = await _decodeFrameBgra(entry.videoPath, at, w, h);
    if (bgra == null) {
      throw StateError('thumbnail decode failed for ${entry.videoPath}');
    }

    // 2) Load sidecars. Meta loads first so its duration can seed the
    // project store's single ClipSlice (a thumbnail never re-times,
    // but the loader still wants a real duration).
    final meta = await RecordingMetadata.loadForVideo(entry.videoPath);
    final projectState = await EditorProjectStore(videoPath: entry.videoPath)
        .load(videoDuration: meta.duration ?? Duration.zero);
    final cursor = await CursorRecording.loadFromFile(
            '${entry.videoPath}.cursor.json')
        .catchError((_) => CursorRecording());

    // 3) Compose one styled frame → RGBA at compositor.totalSize.
    final compositor = FrameCompositor(
      projectState: projectState,
      cursorRecording: cursor,
      metadata: meta,
      videoSize: videoSize,
      fps: entry.fps,
    );
    final rgba = await compositor.compose(videoFrameBgra: bgra, position: at);
    final outW = compositor.totalSize.width.toInt();
    final outH = compositor.totalSize.height.toInt();

    // 4) RGBA → ui.Image → downscaled PNG (≤640px wide).
    final png = await _encodeDownscaledPng(rgba, outW, outH, maxWidth: 640);
    await outPng.writeAsBytes(png);
  }

  static Future<Uint8List?> _decodeFrameBgra(
      String videoPath, Duration at, int w, int h) async {
    final args = <String>[
      '-loglevel', 'error',
      '-ss', (at.inMicroseconds / 1e6).toStringAsFixed(3),
      '-i', videoPath,
      '-frames:v', '1',
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-',
    ];
    final res = await Process.run(Ffmpeg.resolve(), args, stdoutEncoding: null);
    final out = res.stdout as List<int>;
    final frameSize = w * h * 4;
    if (out.length < frameSize) return null;
    return Uint8List.fromList(out.sublist(0, frameSize));
  }

  static Future<Uint8List> _encodeDownscaledPng(
      Uint8List rgba, int w, int h, {required int maxWidth}) async {
    final src = await _imageFromRgba(rgba, w, h);
    final scale = w > maxWidth ? maxWidth / w : 1.0;
    final dw = (w * scale).round(), dh = (h * scale).round();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final scaled = await recorder.endRecording().toImage(dw, dh);
    try {
      final bd = await scaled.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw StateError('PNG encode returned null for thumbnail');
      return bd.buffer.asUint8List();
    } finally {
      src.dispose();
      scaled.dispose();
    }
  }

  static Future<ui.Image> _imageFromRgba(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}
