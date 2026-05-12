#version 460 core

#include <flutter/runtime_effect.glsl>

// Post-process motion blur applied to a captured snapshot of the
// composed scene. Used to smear the entire frame during camera
// (zoom) transitions, matching how Screen Studio's previews blur
// the dock / UI / wallpaper alongside the cursor.
//
// Motion model: a virtual camera scales around a focal point. A
// world point that's currently at output position p sat at output
// position F + (p - F) * S_prev/S_now one exposure ago. Its motion
// over the exposure window is therefore
//
//     m(p) = (p - F) * (1 - S_prev/S_now)
//
// (a radial vector centred on F; magnitude grows linearly with
// distance from F). The blur samples N points along that vector
// at uniform spacing — equivalent to averaging N substeps of a
// linear zoom ramp during the exposure window.

uniform sampler2D uScene;

// Output rect size in pixels (= scene image size). FlutterFragCoord
// ranges from (0, 0) to uOutputSize.
uniform vec2 uOutputSize;

// Focal point of the radial smear in output (image) pixels.
// Typically the centre of the viewport because PlaybackCanvas
// applies the zoom with alignment=center, but the playground
// passes the actual centre so resizing the canvas doesn't
// invalidate the math.
uniform vec2 uFocal;

// Radial scale delta over the exposure window:
//   uScaleDelta = 1 - S_prev / S_now
// Positive when zooming in (current scale > previous). 0 ⇒ no
// motion ⇒ no blur (early return short-circuits the loop).
uniform float uScaleDelta;

// How many of the [kMaxSamples] tap slots are "active". SkSL
// requires loop bounds to be compile-time constants, so the loop
// always runs [kMaxSamples] iterations and skips contribution for
// indices >= uSampleCount.
uniform float uSampleCount;

// Uniform translation (in image pixels) covering camera pan
// during the exposure window. Non-zero when a cursor-following
// zoom is moving the focal between frames, even if scale is
// constant. Same value for every pixel because a rigid camera
// pan moves all pixels by the same amount.
uniform vec2 uTranslation;

out vec4 fragColor;

// Compile-time tap budget. 64 lets the smear stay continuous even
// when the motion vector spans a large fraction of the frame —
// per-tap step ≤ 2 image pixels at the cap, no discrete-stamp
// stair-stepping visible.
const int kMaxSamples = 64;
const float kMaxSamplesF = 64.0;

void main() {
  vec2 fragCoord = FlutterFragCoord();
  vec2 uv = fragCoord / uOutputSize;

  // No early return for "no motion" — with zero motion every tap
  // samples the same texel, so the averaged result is bit-identical
  // to a straight texture(uScene, uv) lookup. Avoiding the branch
  // removes the visible flicker that used to happen whenever the
  // smoothed focal's tiny epsilon noise crossed the threshold.

  float activeF = clamp(uSampleCount, 2.0, kMaxSamplesF);

  // Motion = radial (scale change, centred on focal) + translation
  // (rigid pan, same for every pixel). The radial term is naturally
  // zero at the focal, so the centre stays sharp during a pure zoom
  // ramp; the translation term is uniform across the frame so a
  // pure pan smears every pixel equally.
  vec2 motion = (fragCoord - uFocal) * uScaleDelta + uTranslation;
  vec4 sum = vec4(0.0);
  float weightSum = 0.0;
  for (int i = 0; i < kMaxSamples; i++) {
    float fi = float(i);
    // Constant trip count, conditional contribution. SkSL refuses
    // to compile a `for (int i = 0; i < N; ...)` where N comes
    // from a uniform.
    if (fi < activeF) {
      float t = fi / (activeF - 1.0);
      vec2 samplePos = fragCoord - motion * t;
      vec2 sampleUv = samplePos / uOutputSize;
      // Skip out-of-bound samples (don't contribute, don't count).
      // The result at an edge pixel comes from only its in-bound
      // taps — fewer contributions ⇒ less smear at the edges,
      // which gives the hard rectangular cut Screen Studio's
      // preview has instead of the edge-colour bleed that
      // clamp-to-edge produced.
      if (sampleUv.x >= 0.0 && sampleUv.x <= 1.0 &&
          sampleUv.y >= 0.0 && sampleUv.y <= 1.0) {
        sum += texture(uScene, sampleUv);
        weightSum += 1.0;
      }
    }
  }
  fragColor = weightSum > 0.0 ? sum / weightSum : texture(uScene, uv);
}
