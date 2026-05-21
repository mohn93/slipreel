import 'package:flutter/foundation.dart' show immutable;

/// Per-project post-processing applied to the recorded cursor track on
/// the way out — *before* anything paints it.
///
/// Three filters are bundled here because they all operate on the same
/// upstream signal (the immutable [CursorRecording] samples) and are
/// chosen by the user from the same "Advanced" inspector section:
///
/// - **End-freeze** ([endFreezeMs] > 0): the last few hundred ms of the
///   recording are almost always "user reaching for the Stop button".
///   Freezing the cursor where it was at `lastTs − endFreezeMs` hides
///   that approach without trimming the video itself.
/// - **Despike** ([removeShakes]): accessibility / pointer-control apps
///   (eye tracker, head pointer, mouse keys) emit single-sample jumps
///   that snap back. We replace each sample whose x or y is more than
///   [shakeThresholdPx] from the median of its 5-sample neighbourhood
///   with that median. Real motion stays untouched because consecutive
///   real samples cluster around the same trend line.
/// - **State-debounce** ([optimizeChanges]): rapid arrow↔I-beam↔hand
///   flapping (cursor crossing tightly-packed UI elements) reads as
///   noise more than information. Instead of trusting the sample's
///   own state we return the *dominant* state across a ±60 ms window —
///   the state that won the popular vote wins. A real, sustained
///   transition (>120 ms) flips the dominant state too; only the
///   sub-window flap gets smoothed away.
///
/// The config is plumbed wherever the rendering pipeline reads the
/// cursor recording (preview painters, focal smoother, accumulation
/// sub-frame stamper, scene-blur fallback, export compositor). All
/// filters live in [cursorAtFiltered]; there is no precompute step,
/// so toggling any field updates the preview live without rebuilding
/// the recording.
@immutable
class CursorPostProcess {
  const CursorPostProcess({
    this.endFreezeMs = 0,
    this.removeShakes = false,
    this.shakeThresholdPx = defaultShakeThresholdPx,
    this.optimizeChanges = false,
  });

  /// No-op config — every filter disabled. Pass this when no per-project
  /// config is available (legacy code paths, tests) and the filter
  /// helper should behave like the raw [cursorAt] lookup.
  static const CursorPostProcess none = CursorPostProcess();

  /// Default threshold (logical pixels) at which a sample is considered
  /// a shake instead of real motion. Tuned for typical 60 Hz cursor
  /// tracking — most real consecutive samples are within 5–15 px even
  /// during fast flicks, and accessibility-driven spikes typically jump
  /// 30+ px in a single sample.
  static const double defaultShakeThresholdPx = 20.0;

  /// How long a cursor state must persist before [optimizeChanges]
  /// "trusts" it. Below this, the surrounding stable state wins.
  /// 120 ms matches what feels natural at 60 Hz cursor recording rates
  /// (≈ 7 samples — enough to distinguish a real transition from a
  /// frame-level flap as the cursor crosses a UI boundary).
  static const int optimizeChangesWindowMs = 120;

  /// Range cap on [endFreezeMs]. 2000 ms (2 s) covers the "I reached
  /// for the stop button" case — longer than that and the user should
  /// just trim the clip.
  static const int endFreezeMaxMs = 2000;

  /// How many milliseconds before the recording's last sample the
  /// cursor should freeze in place. 0 disables the filter.
  final int endFreezeMs;

  /// When true, single-sample outliers are replaced with the local
  /// median (see class-level docs).
  final bool removeShakes;

  /// Pixel threshold for the despike filter. Only meaningful when
  /// [removeShakes] is true; surfaced as a separate slider so the user
  /// can tune sensitivity against their own input device's noise floor.
  final double shakeThresholdPx;

  /// When true, the cursor's reported *state* is the dominant state in
  /// a ±60 ms window around the query time (see class-level docs).
  /// The cursor's *position* is unaffected.
  final bool optimizeChanges;

  /// True when at least one filter does anything. Lets call sites skip
  /// the filtered path entirely (and the per-lookup overhead it would
  /// add) when the user hasn't touched the Advanced section.
  bool get isActive =>
      endFreezeMs > 0 || removeShakes || optimizeChanges;

  CursorPostProcess copyWith({
    int? endFreezeMs,
    bool? removeShakes,
    double? shakeThresholdPx,
    bool? optimizeChanges,
  }) =>
      CursorPostProcess(
        endFreezeMs: endFreezeMs ?? this.endFreezeMs,
        removeShakes: removeShakes ?? this.removeShakes,
        shakeThresholdPx: shakeThresholdPx ?? this.shakeThresholdPx,
        optimizeChanges: optimizeChanges ?? this.optimizeChanges,
      );

  Map<String, dynamic> toJson() => {
        'endFreezeMs': endFreezeMs,
        'removeShakes': removeShakes,
        'shakeThresholdPx': shakeThresholdPx,
        'optimizeChanges': optimizeChanges,
      };

  factory CursorPostProcess.fromJson(Map<String, dynamic> json) {
    final endFreezeRaw = (json['endFreezeMs'] as num?)?.toInt() ?? 0;
    final thresholdRaw = (json['shakeThresholdPx'] as num?)?.toDouble() ??
        defaultShakeThresholdPx;
    return CursorPostProcess(
      endFreezeMs: endFreezeRaw.clamp(0, endFreezeMaxMs),
      removeShakes: (json['removeShakes'] as bool?) ?? false,
      shakeThresholdPx: thresholdRaw.clamp(1.0, 100.0),
      optimizeChanges: (json['optimizeChanges'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorPostProcess &&
          other.endFreezeMs == endFreezeMs &&
          other.removeShakes == removeShakes &&
          other.shakeThresholdPx == shakeThresholdPx &&
          other.optimizeChanges == optimizeChanges;

  @override
  int get hashCode => Object.hash(
        endFreezeMs,
        removeShakes,
        shakeThresholdPx,
        optimizeChanges,
      );
}
