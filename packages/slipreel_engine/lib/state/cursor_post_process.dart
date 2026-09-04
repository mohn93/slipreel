import 'package:flutter/foundation.dart' show immutable;

/// Per-project post-processing applied to the recorded cursor track on
/// the way out — *before* anything paints it.
///
/// Cursor behavior and cleanup filters are bundled here because they all
/// operate on the same
/// upstream signal (the immutable [CursorRecording] samples) and are
/// chosen by the user from the cursor inspector:
///
/// - **End-freeze** ([endFreezeMs] > 0): the last few hundred ms of the
///   recording are almost always "user reaching for the Stop button".
///   Freezing the cursor where it was at `lastTs − endFreezeMs` hides
///   that approach without trimming the video itself.
/// - **Despike** ([removeShakes]): accessibility / pointer-control apps
///   (eye tracker, head pointer, mouse keys) emit single-sample jumps
///   that snap back. A sample is corrected only when it is more than
///   [shakeThresholdPx] off the straight path between its neighbours *and*
///   those neighbours sit close together (the cursor went out and came
///   back). It is then moved onto that path, so a genuine corner or fast
///   flick — where the neighbours are far apart — is left exactly as
///   recorded. Correcting in 2-D against the neighbour path avoids the
///   sideways jog a per-axis median produced on smooth curves.
/// - **State-debounce** ([optimizeChanges]): rapid arrow↔I-beam↔hand
///   flapping (cursor crossing tightly-packed UI elements) reads as
///   noise more than information. The state signal is treated as a series
///   of runs; a run shorter than [optimizeChangesMinRunMs] is folded into
///   the surrounding sustained state. Unlike a sliding majority vote this
///   never previews an upcoming state, so a real transition switches at its
///   true boundary while only the sub-threshold flap is smoothed away.
/// - **Hide while idle** ([hideWhenIdle]): the sprite is suppressed after a
///   short period without meaningful movement or a click. This is a
///   visibility rule, so it is evaluated by the shared visibility helper
///   rather than by the trajectory lookup itself.
/// - **Loop position** ([loopPosition]): during the final second, the cursor
///   follows a smooth synthetic path back to its first recorded position.
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
    this.hideWhenIdle = false,
    this.loopPosition = false,
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

  /// Minimum time a cursor state must persist to be treated as real. A run
  /// of a single state shorter than this is a "flap" (the pointer skimming a
  /// UI boundary for a frame or two) and is absorbed into the surrounding
  /// sustained state by [optimizeChanges]. Genuine transitions — which last
  /// far longer — are untouched and still switch at their true boundary.
  static const int optimizeChangesMinRunMs = 120;

  /// Range cap on [endFreezeMs]. 2000 ms (2 s) covers the "I reached
  /// for the stop button" case — longer than that and the user should
  /// just trim the clip.
  static const int endFreezeMaxMs = 2000;

  /// Time without meaningful pointer motion before [hideWhenIdle] hides the
  /// sprite. Keeping the cursor visible for the first second avoids an
  /// unexplained missing cursor at the opening frame of a recording.
  static const int idleTimeoutMs = 1000;

  /// Small capture jitter below this distance is treated as stationary.
  static const double idleMovementThresholdPx = 2.0;

  /// Duration of the synthetic return-to-start path used by [loopPosition].
  static const int loopDurationMs = 1000;

  /// How many milliseconds before the recording's last sample the
  /// cursor should freeze in place. 0 disables the filter.
  final int endFreezeMs;

  /// When true, a single-sample out-and-back jump is snapped back onto the
  /// path between its neighbours (see class-level docs).
  final bool removeShakes;

  /// Pixel threshold for the despike filter. Only meaningful when
  /// [removeShakes] is true; surfaced as a separate slider so the user
  /// can tune sensitivity against their own input device's noise floor.
  final double shakeThresholdPx;

  /// When true, the cursor's reported *state* has sub-threshold flaps folded
  /// into the surrounding sustained state by run length (see class-level
  /// docs). The cursor's *position* is unaffected.
  final bool optimizeChanges;

  /// Hide the cursor after [idleTimeoutMs] without meaningful movement or a
  /// click. Rendering makes this decision from the recorded timeline, so
  /// pause, scrub, playback, and export agree at a given timestamp.
  final bool hideWhenIdle;

  /// Smoothly move the cursor back to its first recorded position during the
  /// final [loopDurationMs] of the video.
  final bool loopPosition;

  /// True when at least one trajectory filter does anything. Lets call sites
  /// skip the filtered path entirely (and the per-lookup overhead it would
  /// add) when the user has not enabled a trajectory-changing behavior.
  bool get isActive =>
      endFreezeMs > 0 || removeShakes || optimizeChanges || loopPosition;

  CursorPostProcess copyWith({
    int? endFreezeMs,
    bool? removeShakes,
    double? shakeThresholdPx,
    bool? optimizeChanges,
    bool? hideWhenIdle,
    bool? loopPosition,
  }) => CursorPostProcess(
    endFreezeMs: endFreezeMs ?? this.endFreezeMs,
    removeShakes: removeShakes ?? this.removeShakes,
    shakeThresholdPx: shakeThresholdPx ?? this.shakeThresholdPx,
    optimizeChanges: optimizeChanges ?? this.optimizeChanges,
    hideWhenIdle: hideWhenIdle ?? this.hideWhenIdle,
    loopPosition: loopPosition ?? this.loopPosition,
  );

  Map<String, dynamic> toJson() => {
    'endFreezeMs': endFreezeMs,
    'removeShakes': removeShakes,
    'shakeThresholdPx': shakeThresholdPx,
    'optimizeChanges': optimizeChanges,
    'hideWhenIdle': hideWhenIdle,
    'loopPosition': loopPosition,
  };

  factory CursorPostProcess.fromJson(Map<String, dynamic> json) {
    final endFreezeRaw = (json['endFreezeMs'] as num?)?.toInt() ?? 0;
    final thresholdRaw =
        (json['shakeThresholdPx'] as num?)?.toDouble() ??
        defaultShakeThresholdPx;
    return CursorPostProcess(
      endFreezeMs: endFreezeRaw.clamp(0, endFreezeMaxMs),
      removeShakes: (json['removeShakes'] as bool?) ?? false,
      shakeThresholdPx: thresholdRaw.clamp(1.0, 100.0),
      optimizeChanges: (json['optimizeChanges'] as bool?) ?? false,
      hideWhenIdle: (json['hideWhenIdle'] as bool?) ?? false,
      loopPosition: (json['loopPosition'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorPostProcess &&
          other.endFreezeMs == endFreezeMs &&
          other.removeShakes == removeShakes &&
          other.shakeThresholdPx == shakeThresholdPx &&
          other.optimizeChanges == optimizeChanges &&
          other.hideWhenIdle == hideWhenIdle &&
          other.loopPosition == loopPosition;

  @override
  int get hashCode => Object.hash(
    endFreezeMs,
    removeShakes,
    shakeThresholdPx,
    optimizeChanges,
    hideWhenIdle,
    loopPosition,
  );
}
