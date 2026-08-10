import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_compositor.dart';

// Deliberately implements only the pre-optimization ExportCompositor surface.
// If a future change adds another member to that interface, this regression
// test stops compiling and catches the source-compatibility break.
class _LegacyCompositor implements ExportCompositor {
  Duration? advancedTo;

  @override
  Size get totalSize => const Size(1, 1);

  @override
  Size get renderSize => const Size(1, 1);

  @override
  Future<Uint8List> compose({
    required Uint8List bgra,
    required Duration position,
  }) async => bgra;

  @override
  void advance(Duration position) => advancedTo = position;

  @override
  Future<void> dispose() async {}
}

class _AsyncCompositor extends _LegacyCompositor
    implements AsyncExportCompositorAdvance {
  bool asyncAdvanceUsed = false;

  @override
  Future<void> advanceAndWait(Duration position) async {
    asyncAdvanceUsed = true;
    advancedTo = position;
  }
}

void main() {
  test(
    'legacy ExportCompositor implementers remain source-compatible',
    () async {
      final compositor = _LegacyCompositor();
      const position = Duration(milliseconds: 250);

      await advanceExportCompositor(compositor, position);

      expect(compositor.advancedTo, position);
    },
  );

  test('async advancement capability is awaited when implemented', () async {
    final compositor = _AsyncCompositor();
    const position = Duration(milliseconds: 500);

    await advanceExportCompositor(compositor, position);

    expect(compositor.asyncAdvanceUsed, isTrue);
    expect(compositor.advancedTo, position);
  });
}
