/// Blur intensity preset chosen by the user in the editor.
enum BlurIntensity { low, medium, high }

/// Corner radius preset chosen by the user.
enum CornerRadiusPreset { none, subtle, rounded, pronounced }

/// Convert a blur intensity preset to a Gaussian sigma in pixels.
double blurSigmaForIntensity(BlurIntensity i) {
  switch (i) {
    case BlurIntensity.low:
      return 4;
    case BlurIntensity.medium:
      return 12;
    case BlurIntensity.high:
      return 28;
  }
}

/// Convert a corner-radius preset to a pixel value applied to the
/// `BorderRadius.circular(...)` of the video frame.
double cornerRadiusPx(CornerRadiusPreset p) {
  switch (p) {
    case CornerRadiusPreset.none:
      return 0;
    case CornerRadiusPreset.subtle:
      return 8;
    case CornerRadiusPreset.rounded:
      return 16;
    case CornerRadiusPreset.pronounced:
      return 32;
  }
}
