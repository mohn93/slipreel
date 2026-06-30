import 'dart:ui';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';
import '../state/cursor_post_process.dart';

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
/// 2. **Despike** — replaces the bracketing samples' x/y with the
///    5-sample neighbourhood median when the raw value is more than
///    [CursorPostProcess.shakeThresholdPx] off.
/// 3. **State-debounce** — replaces the interpolated `state` with the
///    dominant state across a ±60 ms window around the query time, so
///    a brief flap (cursor crossing a UI boundary for one sample)
///    doesn't change the rendered cursor type.
CursorPosition? cursorAtFiltered(
  CursorRecording recording,
  Duration t,
  CursorPostProcess cfg,
) {
  if (!cfg.isActive) return cursorAt(recording, t);

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
    final frac = (queryUs - before.timestampMicros) /
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
    final dominant = _dominantStateAround(
      samples,
      queryUs,
      CursorPostProcess.optimizeChangesWindowMs * 1000,
    );
    if (dominant != null && dominant != result.state) {
      result = CursorPosition(
        x: result.x,
        y: result.y,
        timestampMicros: result.timestampMicros,
        isClicked: result.isClicked,
        state: dominant,
      );
    }
  }

  return result;
}

/// Returns the raw sample with x/y replaced by the 5-sample neighbourhood
/// median when the sample is more than [thresholdPx] off the median on
/// either axis. The median is robust to a single outlier in a 5-window,
/// which is what an accessibility-driven shake almost always looks like.
CursorPosition _despike(
  List<CursorPosition> samples,
  int idx,
  double thresholdPx,
) {
  final n = samples.length;
  final raw = samples[idx];
  final lo = (idx - 2).clamp(0, n - 1);
  final hi = (idx + 2).clamp(0, n - 1);
  if (hi - lo < 2) return raw; // not enough neighbours to be sure
  final xs = <double>[];
  final ys = <double>[];
  for (var i = lo; i <= hi; i++) {
    xs.add(samples[i].x);
    ys.add(samples[i].y);
  }
  xs.sort();
  ys.sort();
  final mx = xs[xs.length >> 1];
  final my = ys[ys.length >> 1];
  if ((raw.x - mx).abs() > thresholdPx ||
      (raw.y - my).abs() > thresholdPx) {
    return CursorPosition(
      x: mx,
      y: my,
      timestampMicros: raw.timestampMicros,
      isClicked: raw.isClicked,
      state: raw.state,
    );
  }
  return raw;
}

/// Counts cursor states across `[queryUs − window/2, queryUs + window/2]`
/// and returns the one with the highest count, or null if the window
/// contains no samples. On a tie, the state encountered first wins —
/// which matches recording order and is deterministic across calls.
CursorState? _dominantStateAround(
  List<CursorPosition> samples,
  int queryUs,
  int windowMicros,
) {
  final half = windowMicros >> 1;
  final lo = queryUs - half;
  final hi = queryUs + half;
  final counts = <CursorState, int>{};
  for (final s in samples) {
    final ts = s.timestampMicros;
    if (ts < lo) continue;
    if (ts > hi) break; // positions list is time-sorted
    counts[s.state] = (counts[s.state] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  CursorState? best;
  var bestCount = -1;
  counts.forEach((state, c) {
    if (c > bestCount) {
      best = state;
      bestCount = c;
    }
  });
  return best;
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
