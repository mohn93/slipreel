import 'dart:io';

import 'package:slipreel_engine/captions/whisper_resolver.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Wires the ffmpeg/whisper resolvers to the binaries bundled inside the
/// app (Slipreel.app/Contents/Helpers), when present. A dev build with no
/// bundled binaries wires nothing, so the resolvers keep their default
/// Homebrew -> PATH fallback and their not-found errors stay honest about
/// which locations were actually searched.
class NativeDeps {
  NativeDeps._();

  /// Call once early in main(), before any export/caption code can run.
  ///
  /// [executablePath] and [fileExists] are test seams; production uses
  /// [Platform.resolvedExecutable] and the real filesystem.
  static void wireBundledBinaries({
    String? executablePath,
    bool Function(String path)? fileExists,
  }) {
    if (!Platform.isMacOS) return;
    final exe = executablePath ?? Platform.resolvedExecutable;
    final exists = fileExists ?? (p) => File(p).existsSync();
    // .../Contents/MacOS/Slipreel -> .../Contents/Helpers
    final helpers = '${File(exe).parent.parent.path}/Helpers';

    final ffmpeg = '$helpers/ffmpeg';
    // ffprobe is resolved as ffmpeg's sibling, so only wire a bundle that
    // ships both.
    if (exists(ffmpeg) && exists('$helpers/ffprobe')) {
      Ffmpeg.resolver = FfmpegResolver(bundledPath: ffmpeg);
      AppLogger.platform.i('Bundled ffmpeg wired: $ffmpeg');
    }

    final whisper = '$helpers/whisper-cli';
    if (exists(whisper)) {
      Whisper.resolver = WhisperResolver(bundledPath: whisper);
      AppLogger.platform.i('Bundled whisper-cli wired: $whisper');
    }
  }
}
