import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

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
  });

  final ZoomRegion zoom;
  /// 1-based label, e.g. "Zoom 1" / "Zoom 2".
  final int zoomNumber;
  final ValueChanged<ZoomRegion> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;
  final CurveLibrary curveLibrary;
  final ValueChanged<CubicBezierCurve?> onCurveOverrideChanged;

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
              const InspectorSectionDivider(),
              InspectorSlider(
                label: 'Enter duration',
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
                label: 'Exit duration',
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
        InkWell(
          onTap: onClose,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: kInspectorPanel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kInspectorBorder),
            ),
            child: const Icon(Icons.close,
                color: Colors.white70, size: 16),
          ),
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

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _segment(
            label: 'Bounded',
            icon: Icons.crop_free,
            isSelected: mode == FollowMode.bounded,
            onTap: () => onChanged(FollowMode.bounded),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _segment(
            label: 'Centered',
            icon: Icons.center_focus_strong,
            isSelected: mode == FollowMode.centered,
            onTap: () => onChanged(FollowMode.centered),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _segment(
            label: 'Predictive',
            icon: Icons.auto_awesome,
            isSelected: mode == FollowMode.predictive,
            onTap: () => onChanged(FollowMode.predictive),
          ),
        ),
      ],
    );
  }

  Widget _segment({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? kInspectorAccent : kInspectorBorder,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 18,
                color: isSelected ? kInspectorAccent : Colors.white70),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
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
