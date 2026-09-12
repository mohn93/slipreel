import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// An export owns only its unique staging directory until publication.
class SafeExportOutput {
  SafeExportOutput._(this.destination, this.sources, this.directory, this.path);
  final String destination;
  final List<String> sources;
  final Directory directory;
  final String path;

  static Future<void> _check(String destination, List<String> sources) async {
    final target = File(destination);
    final parent = await target.parent.resolveSymbolicLinks();
    final canonicalTarget = await target.exists()
        ? await target.resolveSymbolicLinks()
        : p.join(parent, p.basename(destination));
    for (final source in sources) {
      if (!await File(source).exists()) continue;
      if (canonicalTarget == await File(source).resolveSymbolicLinks() ||
          (await target.exists() &&
              await FileSystemEntity.identical(source, destination))) {
        throw ArgumentError(
          'Choose an export destination different from the original media.',
        );
      }
    }
  }

  static Future<SafeExportOutput> create(
    String destination,
    List<String> sources, {
    Future<Directory> Function(String destination)? createStagingDirectory,
  }) async {
    await _check(destination, sources);
    final directory = await (createStagingDirectory ?? _createDirectory)(
      destination,
    );
    return SafeExportOutput._(
      destination,
      sources,
      directory,
      p.join(directory.path, 'output${p.extension(destination)}'),
    );
  }

  static Future<Directory> _createDirectory(String destination) async {
    if (const String.fromEnvironment('SLIPREEL_DISTRIBUTION') == 'app-store') {
      // NSSavePanel grants the selected file, not permission to create sibling
      // directories. Foundation chooses an owned replacement directory on the
      // destination volume, retaining atomic publication even on external disks.
      final path = await const MethodChannel(
        'slipreel/sandbox-files',
      ).invokeMethod<String>('exportStagingDirectory', destination);
      if (path == null || path.isEmpty) {
        throw StateError('Could not prepare a safe export destination.');
      }
      return Directory(path);
    }
    return File(destination).parent.createTemp('.slipreel-export-');
  }

  Future<void> publish() async {
    await _check(destination, sources);
    if (!await File(path).exists() || await File(path).length() == 0) {
      throw StateError('The encoder did not produce a complete export.');
    }
    // Same-filesystem POSIX rename atomically replaces the destination.
    await File(path).rename(destination);
  }

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
