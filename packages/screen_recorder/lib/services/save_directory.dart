import 'dart:io';

/// Resolves the directory new recordings/exports should default to.
///
/// Uses [defaultSaveLocation] when it is set AND the folder still exists;
/// otherwise falls back to [documentsPath]. [exists] is injectable for tests;
/// production passes a real filesystem check.
String resolveSaveDirectory({
  required String? defaultSaveLocation,
  required String documentsPath,
  bool Function(String path)? exists,
}) {
  final check = exists ?? (path) => Directory(path).existsSync();
  final pref = defaultSaveLocation;
  if (pref != null && pref.isNotEmpty && check(pref)) return pref;
  return documentsPath;
}
