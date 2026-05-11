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

// Compile-time tap budget. Tune up if you need smoother smears at
// the cost of fragment-shader work per pixel.
const int kMaxSamples = 32;
const float kMaxSamplesF = 32.0;

void main() {
  vec2 fragCoord = FlutterFragCoord();
  vec2 uv = fragCoord / uOutputSize;

  // No motion → just pass through the captured scene. Cheap and
  // exact; also keeps the cursor accumulation layer that draws ON
  // TOP of this pass crisp when nothing is moving. "No motion"
  // now means both scale and pan are negligible.
  if (abs(uScaleDelta) < 0.0001 && length(uTranslation) < 0.5) {
    fragColor = texture(uScene, uv);
    return;
  }

  float activeF = clamp(uSampleCount, 2.0, kMaxSamplesF);

  // Motion = radial (scale change, centred on focal) + translation
  // (rigid pan, same for every pixel). The radial term is naturally
  // zero at the focal, so the centre stays sharp during a pure zoom
  // ramp; the translation term is uniform across the frame so a
  // pure pan smears every pixel equally.
  vec2 motion = (fragCoord - uFocal) * uScaleDelta + uTranslation;
  vec4 sum = vec4(0.0);
  for (int i = 0; i < kMaxSamples; i++) {
    float fi = float(i);
    // Constant trip count, conditional contribution. SkSL refuses
    // to compile a `for (int i = 0; i < N; ...)` where N comes
    // from a uniform.
    if (fi < activeF) {
      float t = fi / (activeF - 1.0);
      vec2 samplePos = fragCoord - motion * t;
      vec2 sampleUv = samplePos / uOutputSize;
      // Edge-clamp instead of skipping out-of-bound samples: when
      // the back-in-time position falls outside the captured
      // viewport (typical at the edges during a zoom-out), return
      // the nearest visible pixel's colour rather than nothing.
      // Bleeds the edge colour inward so near-edge regions get
      // *some* smear — pixels literally on the edge still won't
      // blur because all their samples clamp to the same edge
      // colour, but it's noticeably better than the previous
      // black/skip behaviour.
      vec2 clampedUv = clamp(sampleUv, vec2(0.0), vec2(1.0));
      sum += texture(uScene, clampedUv);
    }
  }
  fragColor = sum / activeF;
}
