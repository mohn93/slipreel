import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/snap_preference_store.dart';

/// Holds the snap-on-cut toggle and persists it on every change.
/// Mirrors [AppPaletteController].
class SnapPreferenceController extends StateNotifier<bool> {
  SnapPreferenceController({
    required SnapPreferenceStore store,
    required bool initial,
  })  : _store = store,
        super(initial);

  final SnapPreferenceStore _store;

  void setEnabled(bool value) {
    state = value;
    unawaited(_store.save(value));
  }
}

/// Always overridden in main.dart with a loaded store + the persisted
/// initial value. The default throws to surface missing wiring early.
final snapPreferenceProvider =
    StateNotifierProvider<SnapPreferenceController, bool>(
  (ref) => throw UnimplementedError(
    'Override snapPreferenceProvider in main.dart with a loaded store',
  ),
);
