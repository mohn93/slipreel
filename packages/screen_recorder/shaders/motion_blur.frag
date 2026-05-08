#version 460 core

#include <flutter/runtime_effect.glsl>

// Sprite texture: cursor pre-rendered at the center of a buffer that
// has enough padding for the trail to extend beyond the cursor body.
uniform sampler2D uSprite;

// Output rect size in pixels (matches the destination Rect.fromLTWH
// passed to canvas.drawRect). The shader's FlutterFragCoord ranges
// from (0, 0) to (uOutputSize.x, uOutputSize.y).
uniform vec2 uOutputSize;

// Unit vector along the cursor's instantaneous velocity. The trail
// extends in the OPPOSITE direction of this vector.
uniform vec2 uVelocityDir;

// Maximum trail reach in pixels. The trail fades from full alpha at
// the cursor head to transparent at this distance behind it.
uniform float uReachPx;

out vec4 fragColor;

void main() {
  vec2 fragCoord = FlutterFragCoord();
  vec2 spriteCenter = uOutputSize * 0.5;
  vec2 rel = fragCoord - spriteCenter;

  // Always look up the cursor at its current position first. This
  // captures the cursor sprite's actual silhouette wherever it lies,
  // including parts of the body that extend behind the geometric
  // center along the velocity vector (asymmetric cursors like the
  // macOS arrow have body extending in one direction from the tip).
  vec2 cursorUv = fragCoord / uOutputSize;
  vec4 cursorAtCurrent = vec4(0.0);
  if (cursorUv.x >= 0.0 && cursorUv.x <= 1.0 &&
      cursorUv.y >= 0.0 && cursorUv.y <= 1.0) {
    cursorAtCurrent = texture(uSprite, cursorUv);
  }

  // No-trail short-circuit: when reach is sub-pixel the trail
  // contribution is invisible AND the fade math (-s / uReachPx) would
  // divide by zero. Returning the cursor sample alone here is
  // pixel-identical to the no-blur direct paint, which lets the
  // caller always route through the shader without producing a
  // visible toggle when reach drops to zero (e.g. when smoothed
  // velocity drops below the activation threshold).
  if (uReachPx < 1.0) {
    fragColor = cursorAtCurrent;
    return;
  }

  // Signed projection along velocity direction.
  // s > 0 means the output pixel is FORWARD of the cursor center
  //       (in the direction of motion).
  // s < 0 means it's BEHIND the cursor center (in the trail region).
  float s = dot(rel, uVelocityDir);

  // Forward of cursor center: only the cursor itself contributes.
  if (s >= 0.0) {
    fragColor = cursorAtCurrent;
    return;
  }

  // Behind cursor center: compute the trail contribution.
  // Shifting the sample point FORWARD by |s| lands on the cursor's
  // perpendicular cross-section through center, so the trail's
  // cross-section matches the cursor's silhouette perpendicular to
  // its motion vector.
  vec2 samplePos = fragCoord + uVelocityDir * (-s);
  vec2 trailUv = samplePos / uOutputSize;
  vec4 trail = vec4(0.0);

  if (trailUv.x >= 0.0 && trailUv.x <= 1.0 &&
      trailUv.y >= 0.0 && trailUv.y <= 1.0) {
    vec4 trailSample = texture(uSprite, trailUv);
    // Linear fade from full at s=0 (head) to zero at s=-uReachPx
    // (trail end). Sprite values are premultiplied-alpha, so scaling
    // the whole vec4 is correct.
    float fade = 1.0 - clamp(-s / uReachPx, 0.0, 1.0);
    trail = trailSample * fade;
  }

  // Composite the cursor over the trail. Premultiplied-alpha "over":
  //   out = top + bottom * (1 - top.a)
  // Where the cursor body is opaque (a≈1), the cursor pixel wins;
  // where the cursor is transparent (a=0), the trail shows through.
  fragColor = cursorAtCurrent + trail * (1.0 - cursorAtCurrent.a);
}
