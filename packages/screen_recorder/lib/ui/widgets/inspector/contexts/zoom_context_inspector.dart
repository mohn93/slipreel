import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

/// Properties view shown when a zoom pill is selected on the timeline.
///
/// Every control here mutates the underlying [ZoomRegion] through
/// [onChanged] (or [onCurveOverrideChanged] for the curve override,
/// which needs `clearRampCurveOverride` semantics that don't fit a
/// plain copyWith).
class ZoomContextInspector extends StatelessWidget {
  const ZoomContextInspector({
    super.key,
    required this.zoom,
    required this.zoomNumber,
    required this.onChanged,
    required this.onDelete,
    required this.onClose,
    required this.curveLibrary,
    required this.onCurveOverrideChanged,
    required this.videoSize,
    this.onPlacementPreview,
    this.onPlacementCommit,
  });

  final ZoomRegion zoom;
  /// 1-based label, e.g. "Zoom 1" / "Zoom 2".
  final int zoomNumber;
  final ValueChanged<ZoomRegion> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;
  final CurveLibrary curveLibrary;
  final ValueChanged<CubicBezierCurve?> onCurveOverrideChanged;

  /// Video frame size; needed to drive the placement picker's
  /// coordinate model. Zero ⇒ video not yet measured ⇒ section hidden.
  final Size videoSize;

  /// Live placement preview: fires for every drag-update with the
  /// in-flight rect, so the canvas can live-preview the framing.
  final ValueChanged<Rect>? onPlacementPreview;

  /// Placement commit: fires once on drag release with the final
  /// rect, so the editor can persist it via `updateZoomAt`.
  final ValueChanged<Rect>? onPlacementCommit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          icon: Icons.zoom_in,
          title: 'Zoom $zoomNumber',
          subtitle: _rangeLabel(zoom),
          onClose: onClose,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            // Right-side gutter — the override section can host the
            // curve editor whose drag area must not sit under the
            // macOS Scrollbar's hit zone.
            padding: const EdgeInsets.only(right: 12),
            children: [
              if (!zoom.followCursor && !videoSize.isEmpty) ...[
                const Text(
                  'Placement',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Drag to set the zoom focal.',
                  style: TextStyle(
                    color: kInspectorMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                ZoomPlacementPicker(
                  videoSize: videoSize,
                  rect: zoom.rect,
                  zoomLevel: zoom.zoomLevel,
                  onPreview: (r) => onPlacementPreview?.call(r),
                  onCommit: (r) => onPlacementCommit?.call(r),
                ),
                const InspectorSectionDivider(),
              ],
              InspectorSlider(
                label: 'Zoom level',
                value: zoom.zoomLevel,
                min: 1,
                max: 5,
                onChanged: (v) =>
                    onChanged(zoom.copyWith(zoomLevel: v)),
                onReset: () =>
                    onChanged(zoom.copyWith(zoomLevel: 2.0)),
                canReset: zoom.zoomLevel != 2.0,
                subtitle: '${zoom.zoomLevel.toStringAsFixed(1)}×',
              ),
              const InspectorSectionDivider(),
              // Debug-only tuning knob for the manual-placement enter-pan
              // back-load. Per-zoom because the sweet spot depends on this
              // region's zoom level; the subtitle reads out the
              // (zoomLevel, backload) pair so the curve can be fit. Only
              // meaningful for manual placements (followCursor off).
              if (kDebugMode && !zoom.followCursor) ...[
                InspectorSlider(
                  label: 'Pan back-load (debug)',
                  subtitle: _panBackloadSubtitle(
                      zoom.zoomLevel, zoom.manualPanBackload),
                  value: zoom.manualPanBackload ?? 1.0,
                  min: 0.0,
                  max: 3.0,
                  onChanged: (v) =>
                      onChanged(zoom.copyWith(manualPanBackload: v)),
                  onReset: () =>
                      onChanged(zoom.copyWith(clearManualPanBackload: true)),
                  canReset: zoom.manualPanBackload != null,
                ),
                const InspectorSectionDivider(),
              ],
              InspectorToggle(
                label: 'Auto-zoom on cursor',
                subtitle:
                    'Camera follows the recorded cursor through the '
                    'zoom region. Off pins the focal to the zoom\'s '
                    'rect center.',
                value: zoom.followCursor,
                onChanged: (v) =>
                    onChanged(zoom.copyWith(followCursor: v)),
              ),
              if (zoom.followCursor) ...[
                const SizedBox(height: 16),
                const Text(
                  'Follow style',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _FollowModeSegmented(
                  mode: zoom.followMode,
                  onChanged: (m) =>
                      onChanged(zoom.copyWith(followMode: m)),
                ),
                if (zoom.followMode == FollowMode.bounded) ...[
                  const SizedBox(height: 16),
                  InspectorSlider(
                    label: 'Deadzone size',
                    subtitle:
                        '${(zoom.deadzoneRatio * 100).round()}% of '
                        'the visible viewport. Cursor stays inside → '
                        'camera holds; outside → camera re-centers. '
                        'At 100% the deadzone fills the framed area; '
                        'past 100% it extends beyond the viewport, so '
                        'the cursor has to wander past the framed area '
                        'before the camera reacts.',
                    value: zoom.deadzoneRatio,
                    min: 0.1,
                    max: 1.5,
                    onChanged: (v) =>
                        onChanged(zoom.copyWith(deadzoneRatio: v)),
                    onReset: () =>
                        onChanged(zoom.copyWith(deadzoneRatio: 0.8)),
                    canReset: (zoom.deadzoneRatio - 0.8).abs() > 1e-6,
                  ),
                ],
                if (zoom.followMode == FollowMode.predictive) ...[
                  const SizedBox(height: 16),
                  InspectorSlider(
                    label: 'Lookahead window',
                    subtitle:
                        '${zoom.predictiveWindow.inMilliseconds} ms of '
                        'cursor history. Camera centers on the median '
                        'dwell location over this window.',
                    value:
                        zoom.predictiveWindow.inMilliseconds.toDouble(),
                    min: 300,
                    max: 4000,
                    onChanged: (v) => onChanged(zoom.copyWith(
                        predictiveWindow:
                            Duration(milliseconds: v.toInt()))),
                    onReset: () => onChanged(zoom.copyWith(
                        predictiveWindow:
                            const Duration(milliseconds: 1500))),
                    canReset: zoom.predictiveWindow !=
                        const Duration(milliseconds: 1500),
                  ),
                ],
                const SizedBox(height: 24),
                InspectorSlider(
                  label: 'Follow duration',
                  subtitle:
                      '${zoom.followDuration.inMilliseconds} ms for the '
                      'camera to settle on a new target',
                  value:
                      zoom.followDuration.inMilliseconds.toDouble(),
                  min: 100,
                  max: 1500,
                  onChanged: (v) => onChanged(zoom.copyWith(
                      followDuration:
                          Duration(milliseconds: v.toInt()))),
                  onReset: () => onChanged(zoom.copyWith(
                      followDuration: const Duration(milliseconds: 700))),
                  canReset: zoom.followDuration !=
                      const Duration(milliseconds: 700),
                ),
              ],
              // Enter / Exit ramp tuning is a developer-only knob now:
              // the on-pill divider handles are gone, ramps scale
              // proportionally with the pill's width, and stored
              // values are only ever overridden manually when tuning
              // the animation feel. Production users never see these
              // sliders. The whole block (including its surrounding
              // dividers) is stripped at release-build tree-shake via
              // `kDebugMode`.
              if (kDebugMode) ...[
                const InspectorSectionDivider(),
                InspectorSlider(
                  label: 'Enter duration (debug)',
                  subtitle:
                      '${zoom.enterDuration.inMilliseconds} ms ramp-in',
                  value:
                      zoom.enterDuration.inMilliseconds.toDouble(),
                  min: 0,
                  max: 1500,
                  onChanged: (v) => onChanged(zoom.copyWith(
                      enterDuration:
                          Duration(milliseconds: v.toInt()))),
                  onReset: () => onChanged(zoom.copyWith(
                      enterDuration: const Duration(milliseconds: 500))),
                  canReset:
                      zoom.enterDuration != const Duration(milliseconds: 500),
                ),
                const SizedBox(height: 24),
                InspectorSlider(
                  label: 'Exit duration (debug)',
                  subtitle:
                      '${zoom.exitDuration.inMilliseconds} ms ramp-out',
                  value:
                      zoom.exitDuration.inMilliseconds.toDouble(),
                  min: 0,
                  max: 1500,
                  onChanged: (v) => onChanged(zoom.copyWith(
                      exitDuration:
                          Duration(milliseconds: v.toInt()))),
                  onReset: () => onChanged(zoom.copyWith(
                      exitDuration: const Duration(milliseconds: 500))),
                  canReset:
                      zoom.exitDuration != const Duration(milliseconds: 500),
                ),
              ],
              const InspectorSectionDivider(),
              InspectorToggle(
                label: 'Animation override',
                subtitle: 'Use a custom curve for this region\'s ramp.',
                value: zoom.rampCurveOverride != null,
                onChanged: (v) {
                  if (v) {
                    onCurveOverrideChanged(
                      const CubicBezierCurve(
                          x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
                    );
                  } else {
                    onCurveOverrideChanged(null);
                  }
                },
              ),
              if (zoom.rampCurveOverride != null)
                CurveEditor(
                  curve: zoom.rampCurveOverride!,
                  duration: Duration.zero, // unused — slider hidden
                  durationLabel: '',
                  durationMin: Duration.zero,
                  durationMax: Duration.zero,
                  onCurveChanged: onCurveOverrideChanged,
                  onDurationChanged: (_) {},
                  library: curveLibrary,
                  showDurationSlider: false,
                ),
              const InspectorSectionDivider(),
              _DeleteButton(onPressed: onDelete),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  static String _rangeLabel(ZoomRegion z) {
    String fmt(Duration d) {
      final m = d.inMinutes;
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }
    return '${fmt(z.startTime)} → ${fmt(z.endTime)}';
  }

  /// Readout for the debug pan-back-load knob. Surfaces the
  /// (zoomLevel, backload) pair so tuning produces clean data points.
  /// 1.0 = lock-step with the zoom; <1 leads the zoom; >1 lags it.
  /// `null` ⇒ the zoom-level-aware default fit (shown as "(auto)").
  static String _panBackloadSubtitle(double zoomLevel, double? v) {
    final z = '${zoomLevel.toStringAsFixed(2)}×';
    final effective =
        v ?? ZoomFocalController.manualBackloadForZoom(zoomLevel);
    final n = '${effective.toStringAsFixed(2)}×';
    final feel = (effective - 1.0).abs() < 0.01
        ? 'lock-step'
        : (effective < 1.0 ? 'pan leads' : 'pan lags');
    final src = v == null ? ' (auto)' : '';
    return 'zoom $z · back-load $n$src — $feel';
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onClose,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: kInspectorAccent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: kInspectorAccent, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: kInspectorMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        SpringyIconButton(
          icon: Icons.close,
          tooltip: 'Close zoom inspector',
          isActive: false,
          onTap: onClose,
          size: 32,
          iconSize: 16,
          tooltipPlacement: SpringyTooltipPlacement.bottom,
        ),
      ],
    );
  }
}

class _FollowModeSegmented extends StatelessWidget {
  const _FollowModeSegmented({
    required this.mode,
    required this.onChanged,
  });

  final FollowMode mode;
  final ValueChanged<FollowMode> onChanged;

  static const List<(FollowMode, String, IconData)> _options = [
    (FollowMode.bounded, 'Bounded', Icons.crop_free),
    (FollowMode.centered, 'Centered', Icons.center_focus_strong),
    (FollowMode.predictive, 'Predictive', Icons.auto_awesome),
  ];

  @override
  Widget build(BuildContext context) {
    // Matches the cursor / audio / slice preset rows — a Wrap of
    // [InspectorChip]s in `dense` mode. The earlier custom card-tile
    // layout (Expanded + per-tile vertical column) was inconsistent
    // with the rest of the inspector AND the SpringHoverButton's
    // magnetic lean leaked sideways out of the narrow Expanded
    // slots, leaving a ghost-card silhouette in the gap between
    // tiles on hover.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (m, label, icon) in _options)
          InspectorChip(
            label: label,
            icon: icon,
            selected: mode == m,
            onTap: () => onChanged(m),
            dense: true,
          ),
      ],
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: onPressed,
      borderRadius: 10,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF3A1F26),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF8B2E3F)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline,
                color: Color(0xFFE57373), size: 18),
            SizedBox(width: 8),
            Text(
              'Delete zoom',
              style: TextStyle(
                color: Color(0xFFE57373),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
