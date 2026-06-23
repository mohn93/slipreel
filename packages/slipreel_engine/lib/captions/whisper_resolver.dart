import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Thrown when no whisper.cpp CLI binary can be located.
class WhisperNotFoundException implements Exception {
  WhisperNotFoundException(this.searchedLocations);

  final List<String> searchedLocations;

  @override
  String toString() =>
      'WhisperNotFoundException: whisper-cli binary not found. '
      'Searched: ${searchedLocations.join(", ")}';
}

/// Locates the whisper.cpp CLI for a packaged app. Mirrors [FfmpegResolver]:
/// bundled binary (drop-in hook for a future bundled build) → Homebrew
/// (`/opt/homebrew/bin`, `/usr/local/bin`) → `PATH`. whisper.cpp ships the CLI
/// as `whisper-cli` today; older builds named it `whisper-cpp` or `main`, so
/// all three names are tried at each location.
class WhisperResolver {
  WhisperResolver({
    this.bundledPath,
    bool Function(String path)? fileExists,
    String? pathEnv,
  })  : _fileExists = fileExists ?? _defaultFileExists,
        _pathEnv = pathEnv ?? Platform.environment['PATH'] ?? '';

  /// Absolute path to a bundled whisper-cli, when the app ships one. Null today
  /// — the hook a future "bundle a static whisper.cpp" change wires up
  /// (rides the distribution work, same as ffmpeg).
  final String? bundledPath;

  final bool Function(String path) _fileExists;
  final String _pathEnv;

  String? _cached;

  static bool _defaultFileExists(String p) => File(p).existsSync();

  static const List<String> _exeNames = [
    'whisper-cli',
    'whisper-cpp',
    'main',
  ];

  static const List<String> _wellKnownDirs = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ];

  /// Returns the absolute path to the whisper CLI, caching the first success.
  /// Throws [WhisperNotFoundException] if no candidate exists.
  String resolve() {
    final cached = _cached;
    if (cached != null) return cached;

    final searched = <String>[];
    final candidates = <String>[
      if (bundledPath != null) bundledPath!,
      for (final dir in _wellKnownDirs)
        for (final exe in _exeNames) '$dir/$exe',
      ..._pathCandidates(),
    ];
    for (final candidate in candidates) {
      searched.add(candidate);
      if (_fileExists(candidate)) {
        return _cached = candidate;
      }
    }
    throw WhisperNotFoundException(searched);
  }

  Iterable<String> _pathCandidates() sync* {
    if (_pathEnv.isEmpty) return;
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in _pathEnv.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      for (final exe in _exeNames) {
        final name = Platform.isWindows ? '$exe.exe' : exe;
        yield trimmed.endsWith(Platform.pathSeparator)
            ? '$trimmed$name'
            : '$trimmed${Platform.pathSeparator}$name';
      }
    }
  }
}

/// Process-wide whisper-binary facade. Override [resolver] in tests or to inject
/// a bundled path at startup.
class Whisper {
  Whisper._();

  static WhisperResolver resolver = WhisperResolver();

  static String resolve() => resolver.resolve();

  @visibleForTesting
  static void resetForTesting() => resolver = WhisperResolver();
}
