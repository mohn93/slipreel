import 'dart:math' as math;
import 'dart:ui';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';
import '../state/cursor_post_process.dart';

/// Duration of the hide-when-idle vanish/appear transition.
///
/// This deliberately matches the camera bubble's reveal timing: long enough
/// for the fade + blur to read, but short enough that the cursor responds as
/// soon as motion resumes.
const Duration kCursorIdleRevealDuration = Duration(milliseconds: 280);

/// Peak Gaussian blur (canvas pixels) when the idle cursor is fully hidden.
const double kCursorIdleRevealBlurSigmaPx = 12.0;

/// Extra scale at the hidden end of the idle transition. The cursor expands
/// to 1.28x as it vanishes, then contracts to its original size as it appears.
const double kCursorIdleRevealScaleAmount = 0.28;

/// Cursor scale paired with [cursorRevealAt].
///
/// A fully revealed cursor is always its original size. Moving toward hidden
/// expands it into the blur so the vanish reads clearly; appearance naturally
/// runs this in reverse and settles back to 1x.
double cursorIdleScaleForReveal(double reveal) =>
    1.0 + (1.0 - reveal.clamp(0.0, 1.0)) * kCursorIdleRevealScaleAmount;

/// Returns the interpolated cursor position at the given time, or null if
/// the recording is empty.
///
/// This wraps [CursorRecording.getPositionAt] in a typed [Duration] API and
/// is the single source of truth for cursor-time lookups across the export
/// compositor and the preview overlay painter.
CursorPosition? cursorAt(CursorRecording recording, Duration t) {
  return recording.getPositionAt(t.inMicroseconds);
}

/// Returns the recorded sample whose timestamp is *closest* to [t] — no
/// interpolation. Used by the None ("snap") cursor preset so the rendered
/// cursor lands on the exact recorded grid instead of an in-between
/// linearly-interpolated value.
CursorPosition? cursorAtNearest(CursorRecording recording, Duration t) {
  return recording.getPositionAt(t.inMicroseconds, nearestSample: true);
}

/// [cursorAt] with the per-project [CursorPostProcess] applied. When the
/// config is [CursorPostProcess.none] (or none of its flags are active),
/// this is identical to [cursorAt] — there is no per-lookup overhead in
/// the disabled case. When any filter is active, the lookup re-implements
/// the bracketing-pair binary search so we can despike the *raw* samples
/// before interpolating between them (despiking the interpolated output
/// would average a spike with its neighbours instead of replacing it).
///
/// Filters applied, in order:
///
/// 1. **End-freeze** — clamps the query time to `lastTs − endFreezeMs`,
///    so the cursor visually stops at the moment the user reached for
///    Stop Recording without trimming the underlying video.
/// 2. **Despike** — corrects a single sample the cursor jumps to and
///    immediately returns from (an accessibility shake), snapping it onto
///    the time-interpolated path between its neighbours when it is more than
///    [CursorPostProcess.shakeThresholdPx] off it *and* the neighbours are
///    close together (a real corner or flick is kept). See [_despike].
/// 3. **State-debounce** — folds a state run shorter than
///    [CursorPostProcess.optimizeChangesMinRunMs] into the surrounding
///    sustained state, so a brief flap (cursor crossing a UI boundary for a
///    frame or two) doesn't change the rendered cursor type, while genuine
///    transitions still switch at their true boundary. See [_debouncedStateAt].
CursorPosition? cursorAtFiltered(
  CursorRecording recording,
  Duration t,
  CursorPostProcess cfg, {
  Duration? loopEnd,
}) {
  if (!cfg.loopPosition) {
    return _cursorAtFilteredCore(recording, t, cfg);
  }

  final samples = recording.positions;
  if (samples.isEmpty) return null;
  final firstUs = samples.first.timestampMicros;
  final endUs = loopEnd?.inMicroseconds ?? samples.last.timestampMicros;
  if (endUs <= firstUs) {
    return _cursorAtFilteredCore(recording, t, cfg);
  }

  final loopStartUs = math.max(
    firstUs,
    endUs - CursorPostProcess.loopDurationMs * 1000,
  );
  final queryUs = t.inMicroseconds;
  if (queryUs < loopStartUs) {
    return _cursorAtFilteredCore(recording, t, cfg);
  }

  final baseConfig = cfg.copyWith(loopPosition: false);
  final start = _cursorAtFilteredCore(
    recording,
    Duration(microseconds: loopStartUs),
    baseConfig,
  );
  final initial = _cursorAtFilteredCore(
    recording,
    Duration(microseconds: firstUs),
    baseConfig.copyWith(endFreezeMs: 0),
  );
  if (start == null || initial == null) return start ?? initial;
  if (queryUs <= loopStartUs) return start;

  final linear = ((queryUs - loopStartUs) / (endUs - loopStartUs))
      .clamp(0.0, 1.0)
      .toDouble();
  // Smoothstep has zero velocity at both ends, so enabling the option does
  // not introduce a visible corner where recorded motion hands off to the
  // synthetic return path or where the loop lands on the opening position.
  final eased = linear * linear * (3.0 - 2.0 * linear);
  return CursorPosition(
    x: start.x + (initial.x - start.x) * eased,
    y: start.y + (initial.y - start.y) * eased,
    timestampMicros: queryUs,
    // A generated return path must never manufacture a click animation.
    isClicked: false,
    state: eased < 0.5 ? start.state : initial.state,
  );
}

CursorPosition? _cursorAtFilteredCore(
  CursorRecording recording,
  Duration t,
  CursorPostProcess cfg,
) {
  if (cfg.endFreezeMs <= 0 && !cfg.removeShakes && !cfg.optimizeChanges) {
    return cursorAt(recording, t);
  }

  final samples = recording.positions;
  if (samples.isEmpty) return null;

  // 1. End-freeze. Clamp the query forward to the freeze cap; everything
  //    downstream then re-uses the cap's bracketing samples, so position
  //    AND state freeze together (no interpolation past the cap).
  var queryUs = t.inMicroseconds;
  if (cfg.endFreezeMs > 0) {
    final lastUs = samples.last.timestampMicros;
    final cap = lastUs - cfg.endFreezeMs * 1000;
    if (queryUs > cap) queryUs = cap;
  }

  // 2. Find the bracketing pair via binary search — same algorithm as
  //    CursorRecording.getPositionAt but we keep both indices so we
  //    can despike each raw sample independently.
  int low = 0;
  int high = samples.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final mts = samples[mid].timestampMicros;
    if (mts == queryUs) {
      low = mid;
      high = mid;
      break;
    } else if (mts < queryUs) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  final beforeIdx = high >= 0 ? high : low;
  final afterIdx = low < samples.length ? low : high;

  CursorPosition before = samples[beforeIdx.clamp(0, samples.length - 1)];
  CursorPosition after = samples[afterIdx.clamp(0, samples.length - 1)];

  // 3. Despike each bracketing sample against its 5-sample neighbourhood.
  if (cfg.removeShakes) {
    before = _despike(samples, beforeIdx, cfg.shakeThresholdPx);
    after = _despike(samples, afterIdx, cfg.shakeThresholdPx);
  }

  // 4. Interpolate (or pick one if same / coincident timestamps).
  CursorPosition result;
  if (beforeIdx == afterIdx ||
      before.timestampMicros == after.timestampMicros) {
    result = CursorPosition(
      x: before.x,
      y: before.y,
      timestampMicros: queryUs,
      isClicked: before.isClicked,
      state: before.state,
    );
  } else {
    final frac =
        (queryUs - before.timestampMicros) /
        (after.timestampMicros - before.timestampMicros);
    result = CursorPosition(
      x: before.x + (after.x - before.x) * frac,
      y: before.y + (after.y - before.y) * frac,
      timestampMicros: queryUs,
      isClicked: before.isClicked || after.isClicked,
      state: frac < 0.5 ? before.state : after.state,
    );
  }

  // 5. State debounce.
  if (cfg.optimizeChanges) {
    final debounced = _debouncedStateAt(
      samples,
      queryUs,
      CursorPostProcess.optimizeChangesMinRunMs * 1000,
    );
    if (debounced != null && debounced != result.state) {
      result = CursorPosition(
        x: result.x,
        y: result.y,
        timestampMicros: result.timestampMicros,
        isClicked: result.isClicked,
        state: debounced,
      );
    }
  }

  return result;
}

/// [cursorAtFiltered] with GEOMETRIC path smoothing: a Gaussian-weighted
/// average of the filtered path over a symmetric time window around [t].
/// This is what makes the Smooth preset glide along an idealized version
/// of the recorded path — hand jitter and jagged corners are rounded in
/// SPACE, without adding phase lag in TIME (the window looks ahead as
/// much as behind, unlike the spring chase).
///
/// Nine taps at `t + k·(σ/2)`, `k = −4..4` (±2σ reach), with weights
/// `exp(−k²/8)` renormalized over the taps that resolved. Only x/y are
/// averaged — `isClicked`/`state`/`timestampMicros` come from the CENTER
/// tap so click semantics are exactly [cursorAtFiltered]'s. A stationary
/// segment averages to the point itself, so rest positions (and click
/// landings) are exact.
///
/// Pure function of ([recording], [t], [cfg], [sigma]) — no state — so
/// scrub == play == export by construction. [sigma] == zero returns the
/// center tap unchanged.
CursorPosition? smoothedCursorAt(
  CursorRecording recording,
  Duration t,
  CursorPostProcess cfg,
  Duration sigma, {
  Duration? lowerBound,
  Duration? upperBound,
  Duration? loopEnd,
}) {
  if (lowerBound != null && t < lowerBound) return null;
  if (upperBound != null && t > upperBound) return null;
  final center = cursorAtFiltered(recording, t, cfg, loopEnd: loopEnd);
  if (center == null || sigma <= Duration.zero) return center;

  final samples = recording.positions;
  if (samples.isEmpty) return center;

  // The kernel reaches ±2σ. Taper σ toward zero as the query approaches
  // either recording boundary so the first and last recorded positions stay
  // exact. The old asymmetric/clamped kernel pulled the first point forward
  // and the final point backward on a moving path.
  final queryUs = t.inMicroseconds;
  final firstUs = math.max(
    samples.first.timestampMicros,
    lowerBound?.inMicroseconds ?? samples.first.timestampMicros,
  );
  final lastUs = math.min(
    samples.last.timestampMicros,
    upperBound?.inMicroseconds ?? samples.last.timestampMicros,
  );
  final availableBeforeUs = math.max(0, queryUs - firstUs);
  final availableAfterUs = math.max(0, lastUs - queryUs);
  final effectiveSigmaUs = math.min(
    sigma.inMicroseconds.toDouble(),
    math.min(availableBeforeUs / 2.0, availableAfterUs / 2.0),
  );
  if (effectiveSigmaUs <= 0) return center;

  final halfStepUs = effectiveSigmaUs / 2.0;
  var wSum = 0.0;
  var xSum = 0.0;
  var ySum = 0.0;
  for (var k = -4; k <= 4; k++) {
    final tapUs = t.inMicroseconds + (k * halfStepUs).round();
    if (tapUs < firstUs || tapUs > lastUs) {
      continue;
    }
    final tap = k == 0
        ? center
        : cursorAtFiltered(
            recording,
            Duration(microseconds: tapUs),
            cfg,
            loopEnd: loopEnd,
          );
    if (tap == null) continue;
    final w = math.exp(-(k * k) / 8.0);
    wSum += w;
    xSum += tap.x * w;
    ySum += tap.y * w;
  }
  if (wSum <= 0) return center;

  return CursorPosition(
    x: xSum / wSum,
    y: ySum / wSum,
    timestampMicros: center.timestampMicros,
    isClicked: center.isClicked,
    state: center.state,
  );
}

/// Whether the cursor sprite should be painted at [position].
///
/// With [CursorPostProcess.hideWhenIdle] disabled this is a zero-cost `true`.
/// When enabled, the answer is derived only from the cursor timeline: the
/// cursor remains visible for the first second of a clip/run, while clicked,
/// or for one second after it moves at least two pixels. This makes pause,
/// scrubbing, playback, and export deterministic at the same timestamp.
bool cursorVisibleAt(
  CursorRecording recording,
  Duration position,
  CursorPostProcess cfg, {
  Duration cursorDelay = Duration.zero,
  Duration? lowerBound,
  Duration? upperBound,
  Duration? loopEnd,
}) {
  if (!cfg.hideWhenIdle) return true;
  final samples = recording.positions;
  if (samples.isEmpty) return false;

  var query = position - cursorDelay;
  if (lowerBound != null && query < lowerBound) query = lowerBound;
  if (upperBound != null && query > upperBound) query = upperBound;

  final first = Duration(microseconds: samples.first.timestampMicros);
  final visibleFrom = lowerBound != null && lowerBound > first
      ? lowerBound
      : first;
  const timeout = Duration(milliseconds: CursorPostProcess.idleTimeoutMs);
  if (query <= visibleFrom + timeout) return true;

  final windowStart = query - timeout;
  final click = recording.eventIndex.lastClickAtOrBefore(query.inMicroseconds);
  if (click != null && click.timestampMicros >= windowStart.inMicroseconds) {
    return true;
  }

  CursorPosition? anchor = cursorAtFiltered(
    recording,
    windowStart,
    cfg,
    loopEnd: loopEnd,
  );
  if (anchor == null) return false;
  if (anchor.isClicked) return true;
  final thresholdSquared =
      CursorPostProcess.idleMovementThresholdPx *
      CursorPostProcess.idleMovementThresholdPx;

  bool movedTo(CursorPosition sample) {
    if (sample.isClicked) return true;
    final dx = sample.x - anchor.x;
    final dy = sample.y - anchor.y;
    return dx * dx + dy * dy >= thresholdSquared;
  }

  // Visit the real sample boundaries inside the window. Keeping [anchor] at
  // the window's starting point detects gradual sub-pixel motion as soon as
  // its cumulative displacement becomes meaningful, while still ignoring
  // small capture jitter around a stationary cursor.
  var low = 0;
  var high = samples.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (samples[mid].timestampMicros <= windowStart.inMicroseconds) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  for (var i = low; i < samples.length; i++) {
    final ts = samples[i].timestampMicros;
    if (ts >= query.inMicroseconds) break;
    final filtered = cursorAtFiltered(
      recording,
      Duration(microseconds: ts),
      cfg,
      loopEnd: loopEnd,
    );
    if (filtered != null && movedTo(filtered)) return true;
  }

  final current = cursorAtFiltered(recording, query, cfg, loopEnd: loopEnd);
  return current != null && movedTo(current);
}

/// Reveal progress for the hide-when-idle cursor effect.
///
/// Returns 1 while the cursor is fully visible and 0 after it is fully hidden.
/// When the target visibility flips, the value transitions for
/// [revealDuration]: disappearance follows an ease-in cubic curve, while
/// appearance uses the complementary ease-out cubic. Rendering uses
/// `1 - reveal` to increase blur as opacity falls, giving the cursor a soft
/// vanish and the opposite sharpen-and-fade-in when movement resumes.
///
/// The calculation is based only on the recording timeline, so a timestamp
/// produces the same result during playback, scrubbing, and export.
double cursorRevealAt(
  CursorRecording recording,
  Duration position,
  CursorPostProcess cfg, {
  Duration cursorDelay = Duration.zero,
  Duration? lowerBound,
  Duration? upperBound,
  Duration? loopEnd,
  Duration revealDuration = kCursorIdleRevealDuration,
}) {
  if (!cfg.hideWhenIdle) return 1.0;
  if (recording.positions.isEmpty) return 0.0;

  bool visibleAt(Duration t) => cursorVisibleAt(
    recording,
    t,
    cfg,
    cursorDelay: cursorDelay,
    lowerBound: lowerBound,
    upperBound: upperBound,
    loopEnd: loopEnd,
  );

  final visibleNow = visibleAt(position);
  if (revealDuration <= Duration.zero) return visibleNow ? 1.0 : 0.0;

  final previousPosition = position - revealDuration;
  final visibleBefore = visibleAt(previousPosition);
  if (visibleNow == visibleBefore) return visibleNow ? 1.0 : 0.0;

  // Visibility runs last at least idleTimeoutMs (well beyond the reveal
  // duration), so differing endpoints contain exactly one edge. Locate it to
  // microsecond precision without coupling the animation to sample cadence.
  var lowUs = previousPosition.inMicroseconds;
  var highUs = position.inMicroseconds;
  while (highUs - lowUs > 1) {
    final midUs = lowUs + ((highUs - lowUs) >> 1);
    if (visibleAt(Duration(microseconds: midUs)) == visibleBefore) {
      lowUs = midUs;
    } else {
      highUs = midUs;
    }
  }

  final elapsedUs = position.inMicroseconds - highUs;
  final progress = (elapsedUs / revealDuration.inMicroseconds).clamp(0.0, 1.0);
  final remaining = 1.0 - progress;
  return visibleNow
      ? 1.0 - remaining * remaining * remaining
      : remaining * remaining * remaining;
}

/// Removes an accessibility "shake": a sample the cursor jumps to and
/// immediately returns from. Detection is 2-D and gated on a round trip so
/// genuine fast motion — including sharp corners — is left exactly as
/// recorded.
///
/// A shake has two signatures at once:
///
/// 1. **Off the local path.** The sample is more than [thresholdPx] from the
///    point the cursor *would* occupy if it travelled straight between the
///    surrounding stable neighbours, interpolated by timestamp (so uneven
///    sample spacing is handled correctly).
/// 2. **A return, not travel.** Those neighbours are closer to each other
///    than the sample is to the path (net displacement across the excursion
///    is smaller than the excursion itself). A corner or a fast flick fails
///    this test because the neighbours are far apart — real ground was
///    covered — so it is kept untouched.
///
/// When both hold, the sample is replaced with the on-path point rather than
/// a per-axis median: the old median mixed the two axes independently and
/// jogged smooth curves sideways whenever one axis happened to peak.
///
/// This targets the single-sample jump-and-return that accessibility tools
/// produce. A sustained excursion (two or more consecutive displaced
/// samples) is deliberately left untouched — bridging it would require
/// guessing which samples are "real", and mis-guessing distorts genuine
/// motion, which is the exact failure this rewrite removes.
CursorPosition _despike(
  List<CursorPosition> samples,
  int idx,
  double thresholdPx,
) {
  final n = samples.length;
  final raw = samples[idx];
  if (idx <= 0 || idx >= n - 1) return raw; // need a neighbour on both sides

  final before = samples[idx - 1];
  final after = samples[idx + 1];
  final span = after.timestampMicros - before.timestampMicros;
  if (span <= 0) return raw;

  // Point the cursor would occupy on a straight line between its stable
  // neighbours, interpolated by timestamp so uneven spacing is exact.
  final frac = (raw.timestampMicros - before.timestampMicros) / span;
  final pathX = before.x + (after.x - before.x) * frac;
  final pathY = before.y + (after.y - before.y) * frac;
  final devX = raw.x - pathX;
  final devY = raw.y - pathY;
  final devSq = devX * devX + devY * devY;
  final thresholdSq = thresholdPx * thresholdPx;
  if (devSq <= thresholdSq) return raw; // on the local path → real motion

  // Round-trip gate: a shake returns to where it came from, so the
  // neighbours are closer together than the excursion is long. A corner or
  // fast flick covers real ground (neighbours far apart) and is kept.
  final travelX = after.x - before.x;
  final travelY = after.y - before.y;
  final travelSq = travelX * travelX + travelY * travelY;
  if (travelSq >= devSq) return raw;

  return CursorPosition(
    x: pathX,
    y: pathY,
    timestampMicros: raw.timestampMicros,
    isClicked: raw.isClicked,
    state: raw.state,
  );
}

/// Debounces the cursor *state* by run length instead of a sliding majority
/// vote. The recorded state signal is a sequence of runs (maximal stretches
/// of one state); a run shorter than [minRunMicros] of wall time is a "flap"
/// — the pointer skimming a UI boundary for a frame or two — and is folded
/// into the surrounding sustained state.
///
/// Why not a ±window majority (the previous approach): a majority vote reads
/// samples on *both* sides of the query, so as the query approaches a real
/// transition the upcoming run starts winning the count and the rendered
/// state flips up to half a window early. Uneven sampling (a dropped frame
/// before the transition) makes the lead worse. Run length has neither
/// problem: a sustained run is reported for exactly its own extent, so a
/// genuine transition switches at its true boundary, to the microsecond.
///
/// Resolution, given the run containing the query:
/// - **Sustained run** (dwell ≥ [minRunMicros]) → its own state.
/// - **Flap** → the nearest sustained run's state, searching backwards first
///   (the state the cursor is leaving persists through the flap), then
///   forwards. This means a flap between two identical states vanishes, and a
///   one-frame flash on the leading edge of a real transition is suppressed
///   until the new state actually establishes.
/// - **No sustained run in reach** (a very short clip, or a genuinely
///   chattering stretch) → the state of the longest run in the neighbourhood,
///   so the dominant state still wins without a phantom flap.
///
/// Pure function of the samples and [minRunMicros]; identical at the same
/// timestamp across scrub, playback, and export.
CursorState? _debouncedStateAt(
  List<CursorPosition> samples,
  int queryUs,
  int minRunMicros,
) {
  final n = samples.length;
  if (n == 0) return null;

  // Sample whose state the unfiltered lookup would show at queryUs — the
  // same before/after selection cursorAtFiltered uses, so debounce only ever
  // *changes* that state, never disagrees about which sample is current.
  var low = 0;
  var high = n - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final mts = samples[mid].timestampMicros;
    if (mts == queryUs) {
      low = mid;
      high = mid;
      break;
    } else if (mts < queryUs) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  final beforeIdx = (high >= 0 ? high : low).clamp(0, n - 1);
  final afterIdx = (low < n ? low : high).clamp(0, n - 1);
  final int currentIdx;
  if (beforeIdx == afterIdx ||
      samples[beforeIdx].timestampMicros == samples[afterIdx].timestampMicros) {
    currentIdx = beforeIdx;
  } else {
    final frac =
        (queryUs - samples[beforeIdx].timestampMicros) /
        (samples[afterIdx].timestampMicros - samples[beforeIdx].timestampMicros);
    currentIdx = frac < 0.5 ? beforeIdx : afterIdx;
  }

  int runStart(int i) {
    final s = samples[i].state;
    var a = i;
    while (a > 0 && samples[a - 1].state == s) {
      a--;
    }
    return a;
  }

  int runEnd(int i) {
    final s = samples[i].state;
    var b = i;
    while (b < n - 1 && samples[b + 1].state == s) {
      b++;
    }
    return b;
  }

  // Displayed dwell of the run [a, b]: from its first sample to the start of
  // the next run (or its own last sample for the open-ended final run, so a
  // lone trailing sample reads as a flap rather than a sustained state).
  int dwellOf(int a, int b) =>
      (b + 1 < n ? samples[b + 1].timestampMicros : samples[b].timestampMicros) -
      samples[a].timestampMicros;

  final a = runStart(currentIdx);
  final b = runEnd(currentIdx);
  if (dwellOf(a, b) >= minRunMicros) return samples[a].state;

  // Flap: fold into the nearest sustained run. Track the longest run seen as
  // the fallback for clips too short to contain any sustained run.
  var longestState = samples[a].state;
  var longestDwell = dwellOf(a, b);

  var ba = a;
  while (ba > 0) {
    final pb = ba - 1;
    final pa = runStart(pb);
    final d = dwellOf(pa, pb);
    if (d >= minRunMicros) return samples[pa].state;
    if (d > longestDwell) {
      longestDwell = d;
      longestState = samples[pa].state;
    }
    ba = pa;
  }

  var fb = b;
  while (fb < n - 1) {
    final na = fb + 1;
    final nb = runEnd(na);
    final d = dwellOf(na, nb);
    if (d >= minRunMicros) return samples[na].state;
    if (d > longestDwell) {
      longestDwell = d;
      longestState = samples[na].state;
    }
    fb = nb;
  }

  return longestState;
}

/// Maps a cursor position captured in screen coordinates to the corresponding
/// position inside a video of [videoSize], assuming the captured area filled
/// [screenSize]. Used when the recorded video is a different resolution than
/// the screen the cursor was tracked on (e.g. window-only capture, or scaled
/// export).
Offset screenToVideoSpace({
  required Offset screenPos,
  required Size screenSize,
  required Size videoSize,
}) {
  final scaleX = videoSize.width / screenSize.width;
  final scaleY = videoSize.height / screenSize.height;
  return Offset(screenPos.dx * scaleX, screenPos.dy * scaleY);
}
