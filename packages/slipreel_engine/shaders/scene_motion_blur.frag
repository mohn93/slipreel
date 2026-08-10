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
// distance from F). The blur samples N points along four exact camera
// knots. Linear interpolation is limited to each quarter-shutter interval,
// preserving nonlinear easing, curved follow motion, and projective Sweep.

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

// Power-curve exponent for the speed → smear relationship.
// p = 1 → linear (smear ∝ speed). p > 1 → super-linear: slow
// motions blur less than linear, fast motions blur more (more
// cinematic dynamic range). p < 1 → sub-linear, opposite
// emphasis. The reference magnitude `uSpeedCurveRefPx` is the
// pivot — motion at that magnitude gives the same smear at any
// exponent value.
uniform float uSpeedCurveExp;
uniform float uSpeedCurveRefPx;

// Exact current-pose → previous-pose projective mapping for the composed
// z=0 scene plane. The legacy radial+translation signal remains in charge of
// the independently adjustable Screen zoom / Screen movement channels. We
// subtract its approximation over the same projective window, then add this
// homography as a residual so yaw, pitch, perspective and camera movement are
// represented without double-counting scale or pan.
uniform float uHasProjective;
uniform vec3 uProjectiveRow0;
uniform vec3 uProjectiveRow1;
uniform vec3 uProjectiveRow2;
uniform float uProjectiveScaleDelta;
uniform vec2 uProjectiveTranslation;
uniform float uDevicePixelRatio;

// Intermediate exact camera poses at 25%, 50%, and 75% of the shutter.
// The existing uniforms above are the 100% endpoint. With these knots the
// shader follows camera easing and curved cursor-following / 3D Sweep paths
// while retaining one captured image and one GPU pass.
uniform float uHasTrajectory;

uniform float uKnot1ScaleDelta;
uniform vec2 uKnot1Translation;
uniform float uKnot1HasProjective;
uniform vec3 uKnot1ProjectiveRow0;
uniform vec3 uKnot1ProjectiveRow1;
uniform vec3 uKnot1ProjectiveRow2;
uniform float uKnot1ProjectiveScaleDelta;
uniform vec2 uKnot1ProjectiveTranslation;

uniform float uKnot2ScaleDelta;
uniform vec2 uKnot2Translation;
uniform float uKnot2HasProjective;
uniform vec3 uKnot2ProjectiveRow0;
uniform vec3 uKnot2ProjectiveRow1;
uniform vec3 uKnot2ProjectiveRow2;
uniform float uKnot2ProjectiveScaleDelta;
uniform vec2 uKnot2ProjectiveTranslation;

uniform float uKnot3ScaleDelta;
uniform vec2 uKnot3Translation;
uniform float uKnot3HasProjective;
uniform vec3 uKnot3ProjectiveRow0;
uniform vec3 uKnot3ProjectiveRow1;
uniform vec3 uKnot3ProjectiveRow2;
uniform float uKnot3ProjectiveScaleDelta;
uniform vec2 uKnot3ProjectiveTranslation;

out vec4 fragColor;

// Compile-time tap budget. 64 lets the smear stay continuous even
// when the motion vector spans a large fraction of the frame —
// per-tap step ≤ 2 image pixels at the cap, no discrete-stamp
// stair-stepping visible.
const int kMaxSamples = 64;
const float kMaxSamplesF = 64.0;

vec2 cameraPastPosition(
  vec2 fragCoord,
  float scaleDelta,
  vec2 translation,
  float hasProjective,
  vec3 projectiveRow0,
  vec3 projectiveRow1,
  vec3 projectiveRow2,
  float projectiveScaleDelta,
  vec2 projectiveTranslation
) {
  vec2 motion = (fragCoord - uFocal) * scaleDelta + translation;
  if (hasProjective > 0.5) {
    float safeDpr = max(uDevicePixelRatio, 0.001);
    vec3 logicalPoint = vec3(fragCoord / safeDpr, 1.0);
    vec3 projected = vec3(
      dot(projectiveRow0, logicalPoint),
      dot(projectiveRow1, logicalPoint),
      dot(projectiveRow2, logicalPoint)
    );
    if (abs(projected.z) > 0.000001) {
      vec2 projectivePast = projected.xy / projected.z * safeDpr;
      vec2 baselineMotion =
          (fragCoord - uFocal) * projectiveScaleDelta +
          projectiveTranslation;
      vec2 baselinePast = fragCoord - baselineMotion;
      vec2 projectiveResidual = projectivePast - baselinePast;
      motion -= projectiveResidual;
    }
  }
  return fragCoord - motion;
}

void main() {
  vec2 fragCoord = FlutterFragCoord();
  vec2 uv = fragCoord / uOutputSize;

  // No early return for "no motion" — with zero motion every tap
  // samples the same texel, so the averaged result is bit-identical
  // to a straight texture(uScene, uv) lookup. Avoiding the branch
  // removes the visible flicker that used to happen whenever the
  // smoothed focal's tiny epsilon noise crossed the threshold.

  float requestedSamples = clamp(uSampleCount, 2.0, kMaxSamplesF);

  // Motion = radial (scale change, centred on focal) + translation
  // (rigid pan, same for every pixel). Each term is the camera's
  // *actual displacement over the shutter window*: smear length =
  // motion velocity × shutter time. Linear in speed, no thresholds.
  // The radial term is naturally zero at the focal, so the centre
  // stays sharp during a pure zoom ramp; the translation term is
  // uniform across the frame so a pure pan smears every pixel
  // equally.
  vec2 endpointPast = cameraPastPosition(
    fragCoord,
    uScaleDelta,
    uTranslation,
    uHasProjective,
    uProjectiveRow0,
    uProjectiveRow1,
    uProjectiveRow2,
    uProjectiveScaleDelta,
    uProjectiveTranslation
  );
  vec2 motion = fragCoord - endpointPast;
  vec2 knot1Past = fragCoord;
  vec2 knot2Past = fragCoord;
  vec2 knot3Past = fragCoord;
  if (uHasTrajectory > 0.5) {
    knot1Past = cameraPastPosition(
      fragCoord,
      uKnot1ScaleDelta,
      uKnot1Translation,
      uKnot1HasProjective,
      uKnot1ProjectiveRow0,
      uKnot1ProjectiveRow1,
      uKnot1ProjectiveRow2,
      uKnot1ProjectiveScaleDelta,
      uKnot1ProjectiveTranslation
    );
    knot2Past = cameraPastPosition(
      fragCoord,
      uKnot2ScaleDelta,
      uKnot2Translation,
      uKnot2HasProjective,
      uKnot2ProjectiveRow0,
      uKnot2ProjectiveRow1,
      uKnot2ProjectiveRow2,
      uKnot2ProjectiveScaleDelta,
      uKnot2ProjectiveTranslation
    );
    knot3Past = cameraPastPosition(
      fragCoord,
      uKnot3ScaleDelta,
      uKnot3Translation,
      uKnot3HasProjective,
      uKnot3ProjectiveRow0,
      uKnot3ProjectiveRow1,
      uKnot3ProjectiveRow2,
      uKnot3ProjectiveScaleDelta,
      uKnot3ProjectiveTranslation
    );
  }
  // Apply the speed curve to the largest excursion, not only the endpoint.
  // An out-and-back camera move can have a static endpoint but still travel
  // significantly inside the shutter.
  float motionMag = length(motion);
  float pathLength = motionMag;
  if (uHasTrajectory > 0.5) {
    motionMag = max(motionMag, length(fragCoord - knot1Past));
    motionMag = max(motionMag, length(fragCoord - knot2Past));
    motionMag = max(motionMag, length(fragCoord - knot3Past));
    pathLength =
        length(fragCoord - knot1Past) +
        length(knot1Past - knot2Past) +
        length(knot2Past - knot3Past) +
        length(knot3Past - endpointPast);
  }
  float trajectoryScale = 1.0;
  if (motionMag > 0.001 && uSpeedCurveExp != 1.0 && uSpeedCurveRefPx > 0.001) {
    trajectoryScale = pow(
      motionMag / uSpeedCurveRefPx,
      uSpeedCurveExp - 1.0
    );
    motion *= trajectoryScale;
  }
  // Keep taps about two physical pixels apart. The previous fixed 64-tap
  // loop sampled the same texels dozens of times during subtle motion and
  // made software export needlessly expensive. Fast motion still receives
  // the full requested budget; small motion uses only the taps it can resolve.
  float activeF = clamp(
    min(requestedSamples, ceil(pathLength * trajectoryScale / 2.0) + 1.0),
    2.0,
    kMaxSamplesF
  );
  vec4 sum = vec4(0.0);
  float weightSum = 0.0;
  for (int i = 0; i < kMaxSamples; i++) {
    float fi = float(i);
    // Constant trip count, conditional contribution. SkSL refuses
    // to compile a `for (int i = 0; i < N; ...)` where N comes
    // from a uniform.
    if (fi < activeF) {
      float t = fi / (activeF - 1.0);
      vec2 samplePos;
      if (uHasTrajectory > 0.5) {
        if (t <= 0.25) {
          samplePos = mix(fragCoord, knot1Past, t * 4.0);
        } else if (t <= 0.5) {
          samplePos = mix(knot1Past, knot2Past, (t - 0.25) * 4.0);
        } else if (t <= 0.75) {
          samplePos = mix(knot2Past, knot3Past, (t - 0.5) * 4.0);
        } else {
          samplePos = mix(knot3Past, endpointPast, (t - 0.75) * 4.0);
        }
        // Keep the user-tunable speed response without flattening the path:
        // scale each actual trajectory offset around the current pixel.
        samplePos = fragCoord +
            (samplePos - fragCoord) * trajectoryScale;
      } else {
        samplePos = fragCoord - motion * t;
      }
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
