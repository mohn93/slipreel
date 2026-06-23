// packages/screen_recorder/lib/state/whisper_model_store.dart
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The multilingual `small` whisper.cpp ggml model.
const String kWhisperModelFileName = 'ggml-small.bin';
const String kWhisperModelUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin';

/// SHA-256 of the model above (ggml-small.bin, 487 601 967 bytes).
/// Source: HuggingFace LFS pointer for
///   ggerganov/whisper.cpp @ ggml-small.bin (sha256 field).
/// Verified: `shasum -a 256 ggml-small.bin`
const String kWhisperModelSha256 =
    '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b';

/// Downloads [url] to [dest], reporting 0..1 progress. Pulled out as a seam so
/// tests inject a fake and never hit the network.
typedef ModelDownloader = Future<void> Function(
  String url,
  File dest,
  void Function(double progress)? onProgress,
);

/// Ensures the whisper `small` model is present on disk; downloads + verifies it
/// on first use and caches it under the app-support dir. Mirrors the
/// load-or-extract shape of `waveformProvider`.
class WhisperModelStore {
  WhisperModelStore({
    Directory? baseDir,
    ModelDownloader? downloader,
    String expectedSha256 = kWhisperModelSha256,
    String url = kWhisperModelUrl,
  })  : _baseDir = baseDir,
        _downloader = downloader ?? _httpDownload,
        _expectedSha = expectedSha256,
        _url = url;

  final Directory? _baseDir;
  final ModelDownloader _downloader;
  final String _expectedSha;
  final String _url;

  Future<Directory> _resolveDir() async {
    if (_baseDir != null) return _baseDir;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'whisper'))..createSync(recursive: true);
  }

  /// Returns the absolute model path, downloading + verifying on a miss.
  Future<String> ensureModel({void Function(double progress)? onProgress}) async {
    final dir = await _resolveDir();
    final model = File(p.join(dir.path, kWhisperModelFileName));

    if (model.existsSync() && await _matchesSha(model)) {
      return model.path;
    }

    final part = File('${model.path}.part');
    if (part.existsSync()) part.deleteSync();
    try {
      await _downloader(_url, part, onProgress);
      if (!await _matchesSha(part)) {
        throw Exception('whisper model checksum mismatch (corrupt download)');
      }
      if (model.existsSync()) model.deleteSync();
      await part.rename(model.path);
      return model.path;
    } catch (_) {
      if (part.existsSync()) part.deleteSync();
      if (model.existsSync() && !await _matchesSha(model)) {
        model.deleteSync();
      }
      rethrow;
    }
  }

  Future<bool> _matchesSha(File f) async {
    try {
      final digest = sha256.convert(await f.readAsBytes()).toString();
      return digest == _expectedSha;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _httpDownload(
    String url,
    File dest,
    void Function(double progress)? onProgress,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('model download HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      final sink = dest.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) onProgress?.call(received / total);
        }
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
    } finally {
      client.close(force: true);
    }
  }
}
