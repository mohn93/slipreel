import 'package:flutter/material.dart';

const Color trackBg = Color(0xFF1B1B26);
const Color clipFill = Color(0xFFE69E5A);
const Color clipFillTop = Color(0xFFEBA968);
const Color clipStroke = Color(0xFFC9853F);
const Color zoomFill = Color(0xFF7C6BFF);
const Color zoomFillTop = Color(0xFF8E7DFF);
const Color zoomStroke = Color(0xFF6457E8);
const Color zoomFillSelected = Color(0xFF9080FF);
const Color zoomGhostFill = Color(0x547C6BFF);
const Color zoomGhostStroke = Color(0x807C6BFF);
const Color clipGhostFill = Color(0x33E69E5A);
const Color clipGhostStroke = Color(0x99C9853F);
const Color tickColor = Color(0xFF454555);
const Color labelColor = Color(0xFFAAAAB5);
const Color playheadTop = Color(0xFF4FC3FF);
const Color playheadMid = Color(0xFF6F5BFF);
const Color playheadBottom = Color(0xFF3D26AA);

const Duration kGhostZoomSpan = Duration(seconds: 2);
const Duration kGhostMinSpan = Duration(milliseconds: 250);

const double rulerHeight = 20;
const double laneHeight = 46;
const double laneSpacing = 6;
const double handleHitWidth = 16;
const double zoomPillInset = 2;
const int minZoomDurationMs = 250;
const int minTrimDurationMs = 250;
const double trimHandleInset = 6;
/// Reserved padding above each zoom pill for ancillary chrome. Used to
/// host the floating +/− zoom-level badge; that's gone now, so this is
/// 0 — the pill takes the full lane height. Kept named (not deleted)
/// so call sites can document intent; if you bring back a hover-only
/// affordance above the pill, bump this back up.
const double zoomBadgeAreaHeight = 0;

double pixelsPerSecond(double viewportWidth, Duration total, double scale) {
  if (total.inMilliseconds == 0) return 0.0;
  return viewportWidth / (total.inMilliseconds / 1000.0) * scale;
}

double timeToX(Duration t, double pixelsPerSecond) =>
    t.inMilliseconds / 1000.0 * pixelsPerSecond;

Duration xToTime(double x, double pixelsPerSecond) {
  if (pixelsPerSecond <= 0) return Duration.zero;
  return Duration(milliseconds: (x / pixelsPerSecond * 1000.0).round());
}

double contentWidth(double viewportWidth, double scale) =>
    viewportWidth * scale;
