import 'dart:io';
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
    List<String> sources,
  ) async {
    await _check(destination, sources);
    final directory = await File(
      destination,
    ).parent.createTemp('.slipreel-export-');
    return SafeExportOutput._(
      destination,
      sources,
      directory,
      p.join(directory.path, 'output${p.extension(destination)}'),
    );
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
