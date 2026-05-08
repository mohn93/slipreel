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

  // Signed projection along velocity direction.
  // s > 0 means the output pixel is FORWARD of the cursor head
  //       (in the direction of motion).
  // s < 0 means it's BEHIND the cursor head (in the trail).
  float s = dot(rel, uVelocityDir);

  if (s >= 0.0) {
    // Forward of (or at) the cursor head: just sample the sprite at
    // this position. Outside-cursor pixels naturally come back as
    // transparent because the sprite is mostly empty space.
    vec2 uv = fragCoord / uOutputSize;
    fragColor = texture(uSprite, uv);
    return;
  }

  // Behind the cursor: shift the sample point FORWARD by |s| so that
  // we land on the cursor's perpendicular cross-section through
  // center. This makes the trail's cross-section match the cursor's
  // silhouette perpendicular to its motion vector.
  vec2 samplePos = fragCoord + uVelocityDir * (-s);
  vec2 uv = samplePos / uOutputSize;

  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    fragColor = vec4(0.0);
    return;
  }

  vec4 sprite = texture(uSprite, uv);
  // Linear fade from full alpha at s=0 (head) to 0 at s=-uReachPx
  // (trail end). Clamping handles any rare overflow past the reach.
  float fade = 1.0 - clamp(-s / uReachPx, 0.0, 1.0);
  fragColor = sprite * fade;
}
