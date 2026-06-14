/// Preview-only: shift the playhead back by the measured display latency so the
/// synthetic cursor lands on the frame the texture is actually showing (the
/// AVPlayer texture trails the playback clock under decode load). Clamped at
/// zero. Does NOT touch `cursorDelay` — that is applied separately inside the
/// scene-pass builder and must not be double-counted here.
Duration previewPlayheadWithLatency({
  required Duration playhead,
  required Duration displayLatency,
}) {
  final shifted = playhead - displayLatency;
  return shifted < Duration.zero ? Duration.zero : shifted;
}
