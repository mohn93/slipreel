import 'package:flutter/animation.dart';

import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';

/// The camera bubble's full render state at a source-time instant: where to
/// draw it ([placement]) and how far through the show/hide reveal it is
/// ([reveal], 0..1 where 1 = fully shown). Null when the camera is fully
/// hidden (a gap with no remaining vanish tail).
class CameraRenderState {
  const CameraRenderState({required this.placement, required this.reveal});

  final CameraPlacement placement;
  final double reveal;

  @override
  bool operator ==(Object other) =>
      other is CameraRenderState &&
      other.placement == placement &&
      other.reveal == reveal;

  @override
  int get hashCode => Object.hash(placement, reveal);
}

/// Deterministic, source-time analogue of the preview's `AnimatedCameraBubble`.
///
/// Inside a *visible run* (a maximal interval where [CameraPlacementResolver]
/// yields a placement) the bubble glides as usual and `reveal` is 1 — except at
/// a run's start, where (if it emerges from a hidden gap, i.e. start > 0)
/// `reveal` ramps 0→1 over [revealDuration] eased by `easeOutCubic` (the
/// appear). For [revealDuration] AFTER a run ends, the bubble lingers at its
/// last placement while `reveal` ramps 1→0 eased by `easeInCubic` (the vanish).
/// This makes the exporter fade/blur/slide the camera in and out at region
/// edges exactly like the editor preview, instead of hard-cutting.
///
/// Visibility runs are the intervals where `placementAt != null` (regions
/// merged only on overlap/exact-adjacency), matching the preview's
/// `visible: placement != null` driver — NOT the glide join tolerance.
class CameraRenderResolver {
  const CameraRenderResolver._();

  static const Duration defaultRevealDuration = Duration(milliseconds: 280);

  static CameraRenderState? renderAt(
    Duration position,
    List<CameraRegion> regions, {
    Duration revealDuration = defaultRevealDuration,
    Duration glideDuration = CameraPlacementResolver.defaultGlideDuration,
    Curve glideCurve = Curves.easeInOut,
    Duration joinTolerance = CameraPlacementResolver.defaultJoinTolerance,
  }) {
    if (regions.isEmpty) return null;

    CameraPlacement? placeAt(Duration p) => CameraPlacementResolver.placementAt(
          p,
          regions,
          glideDuration: glideDuration,
          glideCurve: glideCurve,
          joinTolerance: joinTolerance,
        );

    final runs = _mergedRuns(regions, joinTolerance);
    final active = placeAt(position);

    if (active != null) {
      final run = _runContaining(runs, position);
      // No appear ramp at the very start of the timeline (the camera is simply
      // present from frame 0, like pressing play where it's already visible).
      final reveal = (run == null || run.start <= Duration.zero)
          ? 1.0
          : _appear(position - run.start, revealDuration);
      return CameraRenderState(placement: active, reveal: reveal);
    }

    // Gap: is `position` within the vanish tail of the most recent run?
    _Run? prev;
    for (final r in runs) {
      if (r.end <= position) {
        prev = r;
      } else {
        break;
      }
    }
    if (prev != null) {
      final since = position - prev.end;
      if (since >= Duration.zero && since < revealDuration) {
        final frozen =
            placeAt(prev.end - const Duration(microseconds: 1));
        if (frozen != null) {
          return CameraRenderState(
            placement: frozen,
            reveal: _vanish(since, revealDuration),
          );
        }
      }
    }
    return null;
  }

  static double _appear(Duration into, Duration dur) {
    final f = (into.inMicroseconds / dur.inMicroseconds).clamp(0.0, 1.0);
    return f >= 1.0 ? 1.0 : Curves.easeOutCubic.transform(f);
  }

  static double _vanish(Duration since, Duration dur) {
    // Reverse of the forward animation: the controller value runs 1→0 mapped
    // through the easeInCubic reverse curve (mirrors AnimatedCameraBubble).
    final f = (since.inMicroseconds / dur.inMicroseconds).clamp(0.0, 1.0);
    return Curves.easeInCubic.transform((1.0 - f).clamp(0.0, 1.0));
  }

  static _Run? _runContaining(List<_Run> runs, Duration t) {
    for (final r in runs) {
      if (t >= r.start && t < r.end) return r;
    }
    return null;
  }

  /// Maximal intervals where the camera is visible (`placementAt != null`):
  /// regions sorted by start and merged when the next starts within
  /// [joinTolerance] of the current end. m14: this MUST use the same tolerance
  /// `CameraPlacementResolver` glides across, otherwise a sub-tolerance gap
  /// (1–4ms) leaves the bubble continuously placed yet splits the run in two,
  /// so the second segment replays the appear ramp and the reveal flickers
  /// out-and-in at the seam. A gap larger than the tolerance is a real gap and
  /// breaks the run.
  static List<_Run> _mergedRuns(
      List<CameraRegion> regions, Duration joinTolerance) {
    final sorted = [...regions]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final runs = <_Run>[];
    for (final r in sorted) {
      if (runs.isEmpty || r.startTime > runs.last.end + joinTolerance) {
        runs.add(_Run(r.startTime, r.endTime));
      } else if (r.endTime > runs.last.end) {
        runs.last.end = r.endTime;
      }
    }
    return runs;
  }
}

class _Run {
  _Run(this.start, this.end);
  final Duration start;
  Duration end;
}
