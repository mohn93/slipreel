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

// Number of taps along the motion vector, baked as a float since
// SkSL doesn't support integer uniforms cleanly. Cast to int
// inside main.
uniform float uSampleCount;

out vec4 fragColor;

void main() {
  vec2 fragCoord = FlutterFragCoord();
  vec2 uv = fragCoord / uOutputSize;

  // No motion → just pass through the captured scene. Cheap and
  // exact; also keeps the cursor accumulation layer that draws
  // ON TOP of this pass crisp when nothing's moving.
  if (abs(uScaleDelta) < 0.0001) {
    fragColor = texture(uScene, uv);
    return;
  }

  vec2 motion = (fragCoord - uFocal) * uScaleDelta;
  int N = int(uSampleCount);
  if (N < 2) {
    fragColor = texture(uScene, uv);
    return;
  }
  float invN = 1.0 / float(N);
  vec4 sum = vec4(0.0);
  float weightSum = 0.0;
  for (int i = 0; i < N; i++) {
    // t = 0 → current frame (no offset); t = 1 → one exposure ago.
    float t = float(i) / float(N - 1);
    vec2 samplePos = fragCoord - motion * t;
    vec2 sampleUv = samplePos / uOutputSize;
    if (sampleUv.x >= 0.0 && sampleUv.x <= 1.0 &&
        sampleUv.y >= 0.0 && sampleUv.y <= 1.0) {
      sum += texture(uScene, sampleUv);
      weightSum += 1.0;
    }
  }
  fragColor = weightSum > 0.0 ? sum / weightSum : texture(uScene, uv);
}
