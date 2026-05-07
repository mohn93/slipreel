import 'package:flutter/painting.dart';

/// Returns per-axis Gaussian sigmas for [ImageFilter.blur] given the
/// screen layer's translation velocity and the slider intensity.
/// Anisotropic so a horizontal pan blurs horizontally and vice versa.
///
/// Caller passes the result straight to `ImageFilter.blur(sigmaX:
/// sigma.dx, sigmaY: sigma.dy)` — both fields are non-negative, so
/// `Offset.zero` means "do not apply the filter".
///
/// Sigmas below this on BOTH axes round to zero — invisible to the
/// eye but each one would still cost a per-frame `saveLayer` if
/// passed to `ImageFilter.blur`.
Offset screenBlurSigma({
  required Offset velocity,
  required double intensity,
  double referenceSpeed = 800,
  double maxReach = 10,
}) {
  if (intensity <= 0) return Offset.zero;
  final fxX =
      (intensity * velocity.dx.abs() / referenceSpeed).clamp(0.0, 1.0);
  final fxY =
      (intensity * velocity.dy.abs() / referenceSpeed).clamp(0.0, 1.0);
  final sx = fxX * maxReach;
  final sy = fxY * maxReach;
  if (sx < _kSigmaCutoff && sy < _kSigmaCutoff) return Offset.zero;
  return Offset(sx, sy);
}

const double _kSigmaCutoff = 0.05;
