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

// Sprite texture's pixel size — used by the inlined bilinear blocks
// below. Passed from the painter so the shader works with whatever
// oversample factor the painter chose (dpr-scaled bake) without
// needing textureSize() (not available in SkSL).
uniform vec2 uSpriteSize;

out vec4 fragColor;

// Number of samples along the line integral. 40 is dense enough that
// consecutive samples overlap on a 32-px cursor body even at the
// painter's max reach (60 px), so the trail reads as a continuous
// smear instead of stacked discrete copies.
const int kSamples = 40;

// Inverse of (kSamples - 1), pre-computed to avoid a divide inside
// the hot loop. Used for both the per-sample u-position and the
// raised-cosine weight.
const float kInvSamplesM1 = 1.0 / float(kSamples - 1);

const float PI = 3.14159265359;

// SkSL doesn't allow `shader`/`sampler2D` as function parameters, so
// the bilinear sampling is inlined at each call site below. The
// shape: blend the four neighbour texels weighted by the fractional
// part of the UV in pixel-space — guarantees backend-independent
// smoothness regardless of whether the auto-sampler runs nearest
// (Impeller) or linear (Skia).

void main() {
  vec2 fragCoord = FlutterFragCoord();

  // No-trail short-circuit: when reach is sub-pixel the integral is
  // pixel-identical to just returning the cursor sample directly, so
  // skip the sampling loop. Also avoids weightSum=0 / div-by-zero
  // edge cases when reach rounds to 0.
  if (uReachPx < 1.0) {
    vec2 uv = fragCoord / uOutputSize;
    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
      // Inlined bilinear sample of uSprite at uv.
      vec2 px0 = uv * uSpriteSize - 0.5;
      vec2 i0 = floor(px0);
      vec2 f0 = px0 - i0;
      vec2 invSize = 1.0 / uSpriteSize;
      vec4 c00 = texture(uSprite, (i0 + vec2(0.5, 0.5)) * invSize);
      vec4 c10 = texture(uSprite, (i0 + vec2(1.5, 0.5)) * invSize);
      vec4 c01 = texture(uSprite, (i0 + vec2(0.5, 1.5)) * invSize);
      vec4 c11 = texture(uSprite, (i0 + vec2(1.5, 1.5)) * invSize);
      vec4 cx0 = mix(c00, c10, f0.x);
      vec4 cx1 = mix(c01, c11, f0.x);
      fragColor = mix(cx0, cx1, f0.y);
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
  vec2 invSpriteSize = 1.0 / uSpriteSize;
  for (int i = 0; i < kSamples; i++) {
    float t = float(i) * kInvSamplesM1; // [0, 1] across the trail
    float u = uReachPx * t;
    vec2 samplePos = fragCoord + uVelocityDir * u;
    vec2 sampleUv = samplePos / uOutputSize;
    if (sampleUv.x >= 0.0 && sampleUv.x <= 1.0 &&
        sampleUv.y >= 0.0 && sampleUv.y <= 1.0) {
      // Raised-cosine (Hann) exposure profile: full weight at u=0
      // (where the cursor most-recently was) easing smoothly to 0
      // at u=reach (the oldest, dimmest tail). Avoids the hard
      // leading-edge of a triangular taper — the streak fades in
      // and out without a visible discontinuity at the head.
      float weight = 0.5 + 0.5 * cos(PI * t);
      // Inlined bilinear sample of uSprite at sampleUv.
      vec2 px = sampleUv * uSpriteSize - 0.5;
      vec2 ti = floor(px);
      vec2 f = px - ti;
      vec4 c00 = texture(uSprite, (ti + vec2(0.5, 0.5)) * invSpriteSize);
      vec4 c10 = texture(uSprite, (ti + vec2(1.5, 0.5)) * invSpriteSize);
      vec4 c01 = texture(uSprite, (ti + vec2(0.5, 1.5)) * invSpriteSize);
      vec4 c11 = texture(uSprite, (ti + vec2(1.5, 1.5)) * invSpriteSize);
      vec4 cx0 = mix(c00, c10, f.x);
      vec4 cx1 = mix(c01, c11, f.x);
      vec4 sampled = mix(cx0, cx1, f.y);
      trail += sampled * weight;
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
