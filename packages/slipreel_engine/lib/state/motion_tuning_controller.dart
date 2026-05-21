import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/rendering/motion_tuning.dart';

/// Named, shippable [MotionTuning] presets the inspector picker
/// exposes as buttons. The enum acts as the user-facing label too
/// (`MotionTuningPreset.snappy.label` → `"Snappy"`).
enum MotionTuningPreset { defaults, snappy, cinematic }

extension MotionTuningPresetData on MotionTuningPreset {
  String get label => switch (this) {
        MotionTuningPreset.defaults => 'Default',
        MotionTuningPreset.snappy => 'Snappy',
        MotionTuningPreset.cinematic => 'Cinematic',
      };

  MotionTuning get tuning => switch (this) {
        MotionTuningPreset.defaults => MotionTuning.defaults,
        MotionTuningPreset.snappy => MotionTuning.snappy,
        MotionTuningPreset.cinematic => MotionTuning.cinematic,
      };
}

/// Holds the active [MotionTuning] for the app session. Inspector
/// picker writes here; controllers (focal spring, cursor motion,
/// scene blur) read via the [motionTuningProvider] so a preset swap
/// or JSON reload flows through to every consumer.
///
/// Foundation only — wiring the existing controllers to read from
/// this notifier lands in a follow-up commit (P2-8 phase C-2).
class MotionTuningController extends StateNotifier<MotionTuning> {
  MotionTuningController({MotionTuning? initial})
      : super(initial ?? MotionTuning.defaults);

  /// Swap to one of the named presets.
  void usePreset(MotionTuningPreset preset) {
    state = preset.tuning;
  }

  /// Apply an arbitrary [MotionTuning] — e.g. a JSON-loaded custom
  /// config from a sidecar file.
  void replace(MotionTuning next) {
    state = next;
  }

  /// Returns the [MotionTuningPreset] whose tuning matches the
  /// current state (by reference equality with the shippable
  /// presets), or null if the state is custom.
  MotionTuningPreset? get activePreset {
    for (final p in MotionTuningPreset.values) {
      if (identical(state, p.tuning)) return p;
    }
    return null;
  }
}

/// Provider for the active motion tuning. App startup can override
/// the initial via `ProviderScope(overrides: [...])` to seed from a
/// loaded JSON file; otherwise the default ships as the production
/// hand-tuned set.
final motionTuningProvider =
    StateNotifierProvider<MotionTuningController, MotionTuning>(
  (ref) => MotionTuningController(),
);
