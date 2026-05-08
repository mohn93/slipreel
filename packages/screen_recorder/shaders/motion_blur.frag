#version 460 core

#include <flutter/runtime_effect.glsl>

// Sprite texture: cursor pre-rendered at the center of a buffer that
// has enough padding for the trail to extend beyond the cursor body.
uniform sampler2D uSprite;

// Output rect size in pixels (matches the destination Rect.fromLTWH
// passed to canvas.drawRect). The shader's FlutterFragCoord ranges
// from (0, 0) to (uOutputSize.x, uOutputSize.y) — the painter
// translates the canvas so the rect is at canvas origin, so this
// holds under Skia's "fragCoord is canvas-local" semantics.
uniform vec2 uOutputSize;

// Unit vector along the cursor's instantaneous velocity. The trail
// extends in the OPPOSITE direction of this vector; the integration
// itself sweeps along +uVelocityDir from the current fragment.
uniform vec2 uVelocityDir;

// Total trail reach in pixels. The blur integrates the cursor's
// presence at this fragment over an exposure window whose length is
// reach pixels along uVelocityDir.
uniform float uReachPx;

out vec4 fragColor;

// Number of samples along the line integral. 24 is enough that the
// trail reads as a continuous smear at the trail lengths we use
// (reach up to ~60px), without burning frames on a dense screen.
const int kSamples = 24;

void main() {
  vec2 fragCoord = FlutterFragCoord();

  // No-trail short-circuit: when reach is sub-pixel the integral is
  // pixel-identical to just returning the cursor sample directly, so
  // skip the sampling loop. Also avoids weightSum=0 / div-by-zero
  // edge cases when reach rounds to 0.
  if (uReachPx < 1.0) {
    vec2 uv = fragCoord / uOutputSize;
    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
      fragColor = texture(uSprite, uv);
    } else {
      fragColor = vec4(0.0);
    }
    return;
  }

  // Linear motion blur via finite-step line integral along the
  // velocity vector. For a cursor moving with velocity v whose center
  // at time t was C(t) = C0 - v*t (t > 0 = past), an output pixel p
  // is "covered" by the cursor at time t when sprite(p - C(t)) is
  // non-transparent. Integrating that coverage over the exposure
  // window gives:
  //
  //   fragColor(p) ∝ ∫ sprite(delta + v_dir * u) du   for u ∈ [0, reach]
  //
  // where delta = p - C0 (the relative position of p to the cursor's
  // current center). Because the sprite is centered at spriteCenter
  // in the buffer, sprite(q) = texture(uSprite, (spriteCenter + q) / size)
  // and (spriteCenter + delta) is exactly fragCoord, so:
  //
  //   sampleUv = (fragCoord + v_dir * u) / uOutputSize
  //
  // Sweeping u from 0 to reach therefore means: for each output pixel,
  // walk forward along the velocity vector and accumulate cursor
  // coverage. Pixels behind the cursor will hit cursor body somewhere
  // mid-sweep; pixels in front never do.
  vec4 trail = vec4(0.0);
  float weightSum = 0.0;
  for (int i = 0; i < kSamples; i++) {
    float u = uReachPx * (float(i) + 0.5) / float(kSamples);
    vec2 samplePos = fragCoord + uVelocityDir * u;
    vec2 sampleUv = samplePos / uOutputSize;
    if (sampleUv.x >= 0.0 && sampleUv.x <= 1.0 &&
        sampleUv.y >= 0.0 && sampleUv.y <= 1.0) {
      // Triangular exposure profile: full weight at u=0 (where the
      // cursor most-recently was) fading linearly to 0 at u=reach
      // (the oldest, dimmest tail). This is what makes the streak
      // taper visually rather than ending in a hard edge.
      float weight = 1.0 - u / uReachPx;
      trail += texture(uSprite, sampleUv) * weight;
      weightSum += weight;
    }
  }
  if (weightSum > 0.0) {
    trail /= weightSum;
  }

  // The cursor body is the integral itself — a true time-average of
  // cursor coverage along the motion path. During motion the body
  // becomes semi-transparent with overlapping ghost copies (so the
  // cursor visibly "blurs"); when reach drops below 1 the early
  // return above returns the sharp sample. No OVER composite: that
  // would force the body opaque and hide the blur on the cursor
  // itself, leaving only the trail behind it visible.
  fragColor = trail;
}
