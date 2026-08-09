import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';

/// First segment whose half-open range `[start, end)` contains [microseconds],
/// or null. Linear scan — caption counts are small (tens to low hundreds).
CaptionSegment? activeCaptionAt(
  List<CaptionSegment> segments,
  int microseconds,
) {
  for (final s in segments) {
    if (s.isActiveAtMicros(microseconds)) return s;
  }
  return null;
}

/// Base caption font size: a fixed fraction of canvas height, scaled by the
/// user's [fontScale]. 4.5% of height ≈ a comfortable subtitle at 1080p.
double captionFontSize(double canvasHeight, double fontScale) =>
    canvasHeight * 0.045 * fontScale;

/// Paints the active caption (if any) onto [canvas], fixed on the output canvas
/// (NOT zoom-transformed). Used by both the editor preview and export so the
/// two match frame-for-frame. No-op when disabled or no caption is active.
class CaptionRenderer {
  const CaptionRenderer._();

  // Laid-out painters memoized on everything that affects text shaping.
  // paint() runs on EVERY frame a caption is visible (preview at 60 Hz,
  // export per frame) but the shaping inputs only change when the
  // segment or style does. Small LRU: preview and export can be alive
  // simultaneously with different canvas sizes, so a single slot would
  // thrash between them. Evicted painters are disposed.
  static const int _cacheCapacity = 4;
  static final Map<String, TextPainter> _layoutCache = {};

  /// Number of TextPainter layouts performed since the last
  /// [debugResetLayoutCache]. Test-only observability for the memo.
  @visibleForTesting
  static int debugLayoutCount = 0;

  @visibleForTesting
  static void debugResetLayoutCache() {
    for (final tp in _layoutCache.values) {
      tp.dispose();
    }
    _layoutCache.clear();
    debugLayoutCount = 0;
  }

  static TextPainter _layoutFor({
    required String text,
    required CaptionStyle style,
    required double fontSize,
    required double layoutWidth,
  }) {
    final useOutline = style.background == CaptionBackground.outline;
    final key =
        '$text|${style.textColor.toARGB32()}|$useOutline|$fontSize|$layoutWidth';
    final cached = _layoutCache.remove(key);
    if (cached != null) {
      _layoutCache[key] = cached; // re-insert: most recently used
      return cached;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: style.textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          height: 1.2,
          shadows: useOutline
              ? const [
                  Shadow(blurRadius: 0, offset: Offset(1.5, 1.5), color: Color(0xFF000000)),
                  Shadow(blurRadius: 0, offset: Offset(-1.5, -1.5), color: Color(0xFF000000)),
                  Shadow(blurRadius: 2, offset: Offset(0, 0), color: Color(0xCC000000)),
                ]
              : null,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
    )..layout(maxWidth: layoutWidth);
    debugLayoutCount++;
    if (_layoutCache.length >= _cacheCapacity) {
      final oldestKey = _layoutCache.keys.first;
      _layoutCache.remove(oldestKey)!.dispose();
    }
    _layoutCache[key] = tp;
    return tp;
  }

  static void paint(
    ui.Canvas canvas,
    ui.Size canvasSize,
    Duration position,
    List<CaptionSegment> segments,
    CaptionStyle style,
  ) {
    if (!style.enabled) return;
    final seg = activeCaptionAt(segments, position.inMicroseconds);
    if (seg == null || seg.text.isEmpty) return;

    final fontSize = captionFontSize(canvasSize.height, style.fontScale);
    final maxWidth = canvasSize.width * 0.85;
    final hPad = fontSize * 0.5;
    final vPad = fontSize * 0.3;
    final edgeInset = canvasSize.height * 0.06;

    final tp = _layoutFor(
      text: seg.text,
      style: style,
      fontSize: fontSize,
      layoutWidth: maxWidth - hPad * 2,
    );

    final blockWidth = tp.width + hPad * 2;
    final blockHeight = tp.height + vPad * 2;
    final left = (canvasSize.width - blockWidth) / 2;
    final top = style.position == CaptionPosition.bottom
        ? canvasSize.height - edgeInset - blockHeight
        : edgeInset;

    if (style.background == CaptionBackground.box) {
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, blockWidth, blockHeight),
        Radius.circular(fontSize * 0.25),
      );
      canvas.drawRRect(rrect, Paint()..color = const Color(0xC0000000));
    }
    tp.paint(canvas, Offset(left + hPad, top + vPad));
  }
}
