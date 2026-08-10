#version 460 core

#include <flutter/runtime_effect.glsl>

// Short-shutter camera motion blur. The moving scene is sampled from its
// current pose toward one previous pose. Pan and zoom retain their independent
// controls; a current-to-previous homography adds the projective residual for
// 3D Sweep. One interval is deliberate: long curved histories become several
// readable copies of the UI rather than photographic exposure blur.

uniform sampler2D uScene;
uniform vec2 uOutputSize;
uniform vec2 uFocal;
uniform float uScaleDelta;
uniform float uSampleCount;
uniform vec2 uTranslation;

uniform float uHasProjective;
uniform vec3 uProjectiveRow0;
uniform vec3 uProjectiveRow1;
uniform vec3 uProjectiveRow2;
uniform float uProjectiveScaleDelta;
uniform vec2 uProjectiveTranslation;
uniform float uDevicePixelRatio;

out vec4 fragColor;

const int kMaxSamples = 32;
const float kMaxSamplesF = 32.0;

float hash12(vec2 point) {
  vec3 p3 = fract(vec3(point.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

vec2 cameraPastPosition(vec2 fragCoord) {
  vec2 motion = (fragCoord - uFocal) * uScaleDelta + uTranslation;
  if (uHasProjective > 0.5) {
    float safeDpr = max(uDevicePixelRatio, 0.001);
    vec3 logicalPoint = vec3(fragCoord / safeDpr, 1.0);
    vec3 projected = vec3(
      dot(uProjectiveRow0, logicalPoint),
      dot(uProjectiveRow1, logicalPoint),
      dot(uProjectiveRow2, logicalPoint)
    );
    if (abs(projected.z) > 0.000001) {
      vec2 projectivePast = projected.xy / projected.z * safeDpr;
      vec2 baselineMotion =
          (fragCoord - uFocal) * uProjectiveScaleDelta +
          uProjectiveTranslation;
      vec2 baselinePast = fragCoord - baselineMotion;
      motion -= projectivePast - baselinePast;
    }
  }
  return fragCoord - motion;
}

void main() {
  vec2 fragCoord = FlutterFragCoord();
  vec2 endpointPast = cameraPastPosition(fragCoord);
  vec2 motion = fragCoord - endpointPast;

  // A pathological focal jump or perspective corner must not turn into an
  // end-to-end translucent duplicate. Eight percent of the shorter canvas
  // side is ample visual reach while remaining proportional across outputs.
  float maxReach = max(1.0, min(uOutputSize.x, uOutputSize.y) * 0.08);
  float motionLength = length(motion);
  if (motionLength > maxReach) {
    motion *= maxReach / motionLength;
    motionLength = maxReach;
  }

  float requestedSamples = clamp(uSampleCount, 2.0, kMaxSamplesF);
  float activeSamples = clamp(
    min(requestedSamples, ceil(motionLength / 2.0) + 1.0),
    2.0,
    kMaxSamplesF
  );

  // A small stable per-pixel phase breaks up parallel sampling bands without
  // introducing frame-to-frame noise. The parabolic shutter weighting keeps
  // the middle of the exposure dominant, so neither endpoint reads as a
  // second sharp frame.
  float phase = (hash12(floor(fragCoord)) - 0.5) * 0.7;
  vec4 sum = vec4(0.0);
  for (int i = 0; i < kMaxSamples; i++) {
    float fi = float(i);
    if (fi < activeSamples) {
      float t = clamp(
        (fi + phase) / max(activeSamples - 1.0, 1.0),
        0.0,
        1.0
      );
      float weight = 0.25 + 3.0 * t * (1.0 - t);
      vec2 sampleUv = (fragCoord - motion * t) / uOutputSize;

      // Never clamp to the output edge: repeated boundary texels become a
      // bright stripe. Valid covered samples are colour-normalised below,
      // while the current scene alpha supplies the final silhouette.
      if (sampleUv.x >= 0.0 && sampleUv.x <= 1.0 &&
          sampleUv.y >= 0.0 && sampleUv.y <= 1.0) {
        vec4 sampleColor = texture(uScene, sampleUv);
        // Runtime samplers normally return premultiplied color. Enforce that
        // invariant at transparent antialiased edges as well, where decoded
        // images can retain bright RGB under near-zero alpha.
        sampleColor.rgb = min(sampleColor.rgb, vec3(sampleColor.a));
        sum += sampleColor * weight;
      }
    }
  }

  // Preserve the current screen/card silhouette. Normalising the accumulated
  // premultiplied RGB by its own coverage keeps the directional blur bright
  // inside the card, then the current alpha supplies one clean outer edge.
  // This avoids both an outward translucent curtain and the inward dark
  // feather produced by a plain dstIn mask.
  vec4 currentColor = texture(uScene, fragCoord / uOutputSize);
  currentColor.rgb = min(currentColor.rgb, vec3(currentColor.a));
  if (currentColor.a <= 0.000001) {
    fragColor = vec4(0.0);
  } else if (sum.a <= 0.000001) {
    fragColor = currentColor;
  } else {
    vec3 straightBlur = sum.rgb / sum.a;
    fragColor = vec4(straightBlur * currentColor.a, currentColor.a);
  }
}
