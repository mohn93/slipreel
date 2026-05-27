import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Thrown when no ffmpeg binary can be located.
class FfmpegNotFoundException implements Exception {
  FfmpegNotFoundException(this.searchedLocations);

  /// Absolute paths that were checked, in order.
  final List<String> searchedLocations;

  @override
  String toString() => 'FfmpegNotFoundException: ffmpeg binary not found. '
      'Searched: ${searchedLocations.join(", ")}';
}

/// Locates the ffmpeg binary for a packaged app.
///
/// Resolution order: bundled binary (drop-in hook for a future bundled
/// build) → Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`) → `PATH`.
/// A sandboxed/packaged macOS app has a minimal `PATH`, so the well-known
/// install locations are checked before `PATH`.
class FfmpegResolver {
  FfmpegResolver({
    this.bundledPath,
    bool Function(String path)? fileExists,
    String? pathEnv,
  })  : _fileExists = fileExists ?? _defaultFileExists,
        _pathEnv = pathEnv ?? Platform.environment['PATH'] ?? '';

  /// Absolute path to a bundled ffmpeg, when the app ships one. Null today —
  /// this is the hook a future "bundle a static ffmpeg" change wires up.
  final String? bundledPath;

  final bool Function(String path) _fileExists;
  final String _pathEnv;

  /// Holds only a *successful* resolution. A failed lookup is never cached so
  /// [resolve] re-scans on the next call — ffmpeg may be installed mid-session.
  String? _cached;

  static bool _defaultFileExists(String p) => File(p).existsSync();

  static const List<String> _wellKnown = [
    '/opt/homebrew/bin/ffmpeg',
    '/usr/local/bin/ffmpeg',
  ];

  /// Returns the absolute path to ffmpeg, caching the first success.
  /// Throws [FfmpegNotFoundException] if none of the candidates exist.
  String resolve() {
    final cached = _cached;
    if (cached != null) return cached;

    final searched = <String>[];
    final candidates = <String>[
      if (bundledPath != null) bundledPath!,
      ..._wellKnown,
      ..._pathCandidates(),
    ];
    for (final candidate in candidates) {
      searched.add(candidate);
      if (_fileExists(candidate)) {
        return _cached = candidate;
      }
    }
    throw FfmpegNotFoundException(searched);
  }

  Iterable<String> _pathCandidates() sync* {
    if (_pathEnv.isEmpty) return;
    final sep = Platform.isWindows ? ';' : ':';
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    for (final dir in _pathEnv.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      yield trimmed.endsWith(Platform.pathSeparator)
          ? '$trimmed$exe'
          : '$trimmed${Platform.pathSeparator}$exe';
    }
  }
}

/// Process-wide ffmpeg-binary facade. All export code resolves through this
/// so every subprocess uses the same absolute path. Override [resolver] in
/// tests or to inject a bundled path.
class Ffmpeg {
  Ffmpeg._();

  /// The intentional injection point for the ffmpeg binary. Production wires
  /// a bundled-binary path here at startup; tests override it (paired with
  /// [resetForTesting]). Deliberately not `@visibleForTesting` — production
  /// code must be able to set it.
  static FfmpegResolver resolver = FfmpegResolver();

  /// Absolute path to ffmpeg. Throws [FfmpegNotFoundException] if missing.
  static String resolve() => resolver.resolve();

  @visibleForTesting
  static void resetForTesting() => resolver = FfmpegResolver();
}
