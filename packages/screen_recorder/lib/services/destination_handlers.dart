import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// TODO when super_clipboard's file-pasteboard API is needed:
// import 'package:super_clipboard/super_clipboard.dart';
// Currently using vanilla Clipboard.setData for plain-text delivery.
// Replace with super_clipboard's file-reference pasteboard once the
// native API surface stabilises (super_clipboard ≥ 1.0).

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns the file extension including the leading dot, e.g. `".mp4"`.
/// Returns `""` when the name has no extension.
String _fileExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot); // includes the dot
}

/// Returns the last component of a POSIX path, e.g. `"foo.mp4"`.
String _basename(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  return sep < 0 ? path : path.substring(sep + 1);
}

// ---------------------------------------------------------------------------
// DestinationResult
// ---------------------------------------------------------------------------

/// What a [DestinationHandler] returns from `deliver()` so the caller
/// can drive any post-export UI (snackbar, reveal-in-finder button).
class DestinationResult {
  const DestinationResult({
    required this.message,
    this.revealPath,
    this.copiedToClipboard = false,
  });

  /// Short user-facing message — shown in a snackbar by the dialog.
  final String message;

  /// Set when the dialog should offer a "Reveal in Finder" button
  /// pointing at this path (null when there's nothing to reveal).
  final String? revealPath;

  /// True when [DestinationHandler.deliver] has put something on the
  /// system clipboard. The dialog can use this to skip the snackbar
  /// "URL copied" duplicate when the message itself already says so.
  final bool copiedToClipboard;
}

// ---------------------------------------------------------------------------
// DestinationHandler
// ---------------------------------------------------------------------------

abstract class DestinationHandler {
  /// Called BEFORE export — the handler decides where the encoded file
  /// should land. May prompt the user (Save dialog) or pick a tmp path.
  /// Returns null to mean "user cancelled" — the dialog short-circuits
  /// the export.
  Future<String?> resolveOutputPath({required String suggestedFileName});

  /// Called AFTER a successful export with the path that the pipeline
  /// wrote to. Performs delivery (reveal, clipboard copy, future
  /// upload), returns a [DestinationResult] describing what happened.
  Future<DestinationResult> deliver(String outputPath);
}

// ---------------------------------------------------------------------------
// FileSaver
// ---------------------------------------------------------------------------

/// Saves to a user-chosen path via the system Save dialog.
class FileSaver implements DestinationHandler {
  /// Constructs a [FileSaver].
  ///
  /// [saveDialog] is injectable for testing. In production the default
  /// implementation opens the real system Save dialog via `file_selector`.
  FileSaver({
    Future<String?> Function(String suggestedName)? saveDialog,
  }) : _saveDialog = saveDialog ?? _defaultSaveDialog;

  final Future<String?> Function(String suggestedName) _saveDialog;

  static Future<String?> _defaultSaveDialog(String suggestedName) async {
    final ext = _fileExtension(suggestedName); // e.g. ".mp4"
    final XTypeGroup typeGroup;
    if (ext == '.gif') {
      typeGroup = const XTypeGroup(label: 'GIF', extensions: ['gif']);
    } else {
      typeGroup = const XTypeGroup(label: 'MP4 video', extensions: ['mp4']);
    }

    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [typeGroup],
    );
    return location?.path;
  }

  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) =>
      _saveDialog(suggestedFileName);

  @override
  Future<DestinationResult> deliver(String outputPath) async {
    final basename = _basename(outputPath);
    return DestinationResult(
      message: 'Export complete: $basename',
      revealPath: outputPath,
    );
  }
}

// ---------------------------------------------------------------------------
// ClipboardCopier
// ---------------------------------------------------------------------------

/// Writes to a tmp file then copies its absolute path to the system clipboard.
class ClipboardCopier implements DestinationHandler {
  /// Constructs a [ClipboardCopier].
  ///
  /// [clipboardWrite] is injectable for testing. In production the default
  /// uses `Clipboard.setData`.
  ///
  /// [tempDirProvider] is injectable for testing. In production the default
  /// calls `getTemporaryDirectory()`.
  ClipboardCopier({
    Future<void> Function(String text)? clipboardWrite,
    Future<Directory> Function()? tempDirProvider,
  })  : _clipboardWrite = clipboardWrite ?? _defaultClipboardWrite,
        _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  final Future<void> Function(String text) _clipboardWrite;
  final Future<Directory> Function() _tempDirProvider;

  static Future<void> _defaultClipboardWrite(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) async {
    final tmpDir = await _tempDirProvider();
    final ext = _fileExtension(suggestedFileName); // e.g. ".mp4" or ".gif"
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${tmpDir.path}${Platform.pathSeparator}screenflow_export_$ts$ext';
  }

  @override
  Future<DestinationResult> deliver(String outputPath) async {
    // TODO when super_clipboard's file-pasteboard API is needed:
    // Use super_clipboard to write a proper NSPasteboard file reference so
    // the system recognises the clipboard item as a file rather than text.
    // For now plain-text of the absolute path is sufficient and avoids
    // requiring native Swift/ObjC glue code in this task.
    await _clipboardWrite(outputPath);
    return const DestinationResult(
      message: 'Path copied — paste into Finder or any app',
      copiedToClipboard: true,
    );
  }
}

// ---------------------------------------------------------------------------
// ShareableLinkPublisher
// ---------------------------------------------------------------------------

/// Stub for the eventual "Shareable link" feature. Per the plan's
/// "option 2 — UI complete, no backend yet" decision, this writes to
/// a tmp file and copies a `file://<absolute>` URL to the clipboard
/// as text. When the real upload service ships, replace just this
/// class.
class ShareableLinkPublisher implements DestinationHandler {
  /// Constructs a [ShareableLinkPublisher].
  ///
  /// [clipboardWrite] is injectable for testing. In production the default
  /// uses `Clipboard.setData`.
  ///
  /// [tempDirProvider] is injectable for testing. In production the default
  /// calls `getTemporaryDirectory()`.
  ShareableLinkPublisher({
    Future<void> Function(String text)? clipboardWrite,
    Future<Directory> Function()? tempDirProvider,
  })  : _clipboardWrite = clipboardWrite ?? _defaultClipboardWrite,
        _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  final Future<void> Function(String text) _clipboardWrite;
  final Future<Directory> Function() _tempDirProvider;

  static Future<void> _defaultClipboardWrite(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) async {
    final tmpDir = await _tempDirProvider();
    final ext = _fileExtension(suggestedFileName);
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${tmpDir.path}${Platform.pathSeparator}screenflow_export_$ts$ext';
  }

  @override
  Future<DestinationResult> deliver(String outputPath) async {
    final fileUrl = 'file://$outputPath';
    await _clipboardWrite(fileUrl);
    return DestinationResult(
      message: 'URL copied (local file for now — hosted upload coming soon)',
      revealPath: outputPath,
      copiedToClipboard: true,
    );
  }
}
