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

/// Like [previewPlayheadWithLatency], but never lets display-latency *variation*
/// pull the preview time backward during continuous play.
///
/// `displayLatency` is polled at ~8 Hz and EMA-smoothed, so it steps rather than
/// glides. A GPU-heavy zoom in/out transition spikes the real decode latency,
/// which steps the smoothed estimate up sharply and would momentarily push
/// `playhead - displayLatency` *backward*. The downstream zoom-region selector
/// ([ZoomRegion.activeAt], a half-open interval) and the focal spring assume
/// monotonic-forward time, so a backward step makes the region flicker and the
/// focal snap. We convert such a reversal into a brief hold instead.
///
/// Genuine backward *seeks* are still followed: during continuous play the
/// smoothed [rawPlayhead] only ever extrapolates forward, so [rawPlayhead]
/// dropping below [prevRawPlayhead] means a real seek/loop — pass it through and
/// let the caller rebase its history.
///
/// [prevRawPlayhead]/[prevEmitted] are the previous frame's raw input and
/// emitted output, or null on the first frame of a play segment (no clamp).
///
/// The hold is BOUNDED by [kMaxPreviewLag]: a held value can never trail the
/// real [rawPlayhead] by more than that. Display latency is normally a few
/// frames, but a texture stall during a GPU-heavy zoom can make the polled
/// estimate balloon — `adjusted` then stays below `prevEmitted` indefinitely
/// and the unbounded hold would FREEZE the preview clock while playback keeps
/// running (the zoom stuck at full magnification, never ramping out). The
/// floor converts that into a bounded trail so the preview always advances.
Duration steadyPreviewPlayhead({
  required Duration rawPlayhead,
  required Duration displayLatency,
  required Duration? prevRawPlayhead,
  required Duration? prevEmitted,
}) {
  // AVPlayerVideoOutput reports the presentation timestamp at which the
  // current pixel buffer STARTED. On sparse/VFR screen recordings that same
  // buffer can legitimately remain current for hundreds of milliseconds (the
  // fixture that exposed this has a 1.15s packet). Treating the whole
  // `clock - frameStart` age as decode latency pushes cursor/camera time far
  // behind the playback clock, then makes it jump forward when the next frame
  // or the completion event arrives.
  //
  // Genuine preview decode latency is only a few display frames. Bound the
  // correction before the first-frame/no-history return as well as the
  // monotonic floor below; otherwise play-after-seek can still jump backward
  // once by the full VFR packet duration.
  final boundedLatency = displayLatency > kMaxPreviewLag
      ? kMaxPreviewLag
      : displayLatency;
  final adjusted = previewPlayheadWithLatency(
    playhead: rawPlayhead,
    displayLatency: boundedLatency,
  );
  if (prevRawPlayhead == null || prevEmitted == null) return adjusted;
  // Real backward seek/loop — the raw playhead itself moved back. Follow it.
  if (rawPlayhead < prevRawPlayhead) return adjusted;
  // Forward/held raw: suppress latency-induced reversals by holding...
  final held = adjusted < prevEmitted ? prevEmitted : adjusted;
  // ...but never let the hold (or a runaway latency estimate) trail the real
  // clock by more than the bounded max — otherwise the preview freezes.
  final floor = rawPlayhead - kMaxPreviewLag;
  return held < floor ? floor : held;
}

/// Upper bound on how far the steadied preview clock may trail the real
/// playback clock. Fifty milliseconds covers roughly one frame at the
/// timestamp-derived 25fps used by sparse screen captures (and three nominal
/// 60fps frames), while preventing a long VFR packet from masquerading as
/// hundreds of milliseconds of decode latency. Keeping this below
/// PlaybackCanvas's 100ms paused-position stabilization threshold also avoids
/// a correction disappearing as a visible jump on natural completion.
const Duration kMaxPreviewLag = Duration(milliseconds: 50);

/// Whether the preview should render the zoom focal from the deterministic
/// [DeterministicFocalTrack] (a pure function of the playhead) instead of the
/// live, path-dependent focal spring.
///
/// The follow strategies are STATEFUL (the bounded/predictive deadzone gate
/// carries an `_inFlight` hysteresis flag), so the live spring's focal at a
/// given time depends on the path the playhead took to get there — a scrub
/// resets the gate, so "scrub to X then play" diverges from "play from the
/// start", and from export (which renders the deterministic track). Rendering
/// the deterministic track in every state makes preview-play == scrub ==
/// export by construction, and removes the focal-source snap at a play/pause
/// toggle.
///
/// Returns false when a placement override is active (that intentionally drives
/// the focal to a previewed rect) or for non-follow-cursor regions (whose focal
/// is the fixed `rect.center` and already position-pure).
bool shouldUseDeterministicFocal({
  required bool isHoverScrubbing,
  required bool isPlaying,
  required bool hasOverride,
  required bool followCursor,
}) {
  if (hasOverride) return false;
  if (!followCursor) return false;
  return true;
}
