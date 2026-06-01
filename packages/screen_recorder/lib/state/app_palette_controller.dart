import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

/// Holds the active palette selection and persists it on every change.
class AppPaletteController extends StateNotifier<PaletteId> {
  AppPaletteController({
    required AppPaletteStore store,
    PaletteId initial = PaletteId.midnight,
  })  : _store = store,
        super(initial);

  final AppPaletteStore _store;

  void select(PaletteId id) {
    state = id;
    unawaited(_store.save(id));
  }
}

/// Always overridden at startup in `main.dart` with a loaded store +
/// the persisted initial value. The default throws to surface missing
/// wiring early instead of silently falling back to a hard-coded palette.
final appPaletteControllerProvider =
    StateNotifierProvider<AppPaletteController, PaletteId>(
  (ref) => throw UnimplementedError(
    'Override appPaletteControllerProvider in main.dart with a loaded store',
  ),
);
