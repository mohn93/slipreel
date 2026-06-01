import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tips_store.dart';

enum TipId {
  barModePicker,
  editorTrimHandles,
  editorZoomKeyframe,
  editorInspector,
  editorExport,
}

const _copy = {
  TipId.barModePicker:
      'Pick a capture mode: Display, Window, Area, or a connected Device.',
  TipId.editorTrimHandles:
      'Drag these to trim the start and end of your clip.',
  TipId.editorZoomKeyframe:
      'Tap the timeline to add a smooth zoom keyframe.',
  TipId.editorInspector:
      'Customize cursor, background, frame, and motion here.',
  TipId.editorExport:
      'Cmd+E to export with smart presets.',
};

class TipsController extends ChangeNotifier {
  TipsController(this._store);

  final TipsStore _store;
  Set<String> _seen = {};
  TipId? _activeTip;

  Future<void> load() async {
    _seen = await _store.load();
    notifyListeners();
  }

  bool shouldShow(TipId id) => !_seen.contains(id.name);

  Future<void> markSeen(TipId id) async {
    if (_seen.add(id.name)) {
      await _store.markSeen(id.name);
      notifyListeners();
    }
  }

  /// Returns true if `id` becomes the active tip (no other tip is showing).
  /// Caller must `release(id)` when the tip is dismissed.
  bool tryClaim(TipId id) {
    if (_activeTip != null) return false;
    _activeTip = id;
    notifyListeners();
    return true;
  }

  void release(TipId id) {
    if (_activeTip == id) {
      _activeTip = null;
      notifyListeners();
    }
  }

  String copyFor(TipId id) => _copy[id]!;

  TipId? get activeTip => _activeTip;
}

final tipsControllerProvider =
    ChangeNotifierProvider<TipsController>((ref) => throw UnimplementedError(
          'Override tipsControllerProvider in main() with a loaded instance',
        ));
