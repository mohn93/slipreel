import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/state/frame_extractor_provider.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

/// The composed-canvas geometry (wallpaper + padding + bezel + screen)
/// for the currently-edited frame, resolved by `playback_screen` the SAME
/// way the live canvas renders it, and forwarded to [ZoomPlacementPicker]
/// so the placement box matches the render pixel-for-pixel.
///
/// For a normal recording with zero padding and no device frame this
/// degrades to `canvasSize == videoSize`, `videoRect == (0,0,W,H)`,
/// `deviceLayout == null` — i.e. the bare-video behavior.
class ZoomPlacementGeometry {
  const ZoomPlacementGeometry({
    required this.canvasSize,
    required this.videoRect,
    required this.wallpaperCategory,
    required this.wallpaperIndex,
    this.wallpaperSolidColor,
    this.deviceLayout,
    this.bezel,
  });

  /// Composed canvas size in pixels (wallpaper + padding + bezel + screen).
  final Size canvasSize;

  /// The video's rect within the composed canvas (canvas px).
  final Rect videoRect;

  /// Wallpaper category for `wallpaperDecoration`. Null when the project
  /// has no wallpaper — the picker then shows a neutral backdrop, matching
  /// the render (which draws no wallpaper layer in that case).
  final String? wallpaperCategory;

  /// Wallpaper index for `wallpaperDecoration`.
  final int wallpaperIndex;

  /// Custom solid fill color (only for the "Solid" category).
  final Color? wallpaperSolidColor;

  /// Device-frame layout (canvas px). Null for normal recordings.
  final DeviceFrameLayout? deviceLayout;

  /// Device bezel image. Null for normal recordings; non-null whenever
  /// [deviceLayout] is non-null.
  final ImageProvider? bezel;
}

/// Properties view shown when a zoom pill is selected on the timeline.
///
/// Every control here mutates the underlying [ZoomRegion] through
/// [onChanged] (or [onCurveOverrideChanged] for the curve override,
/// which needs `clearRampCurveOverride` semantics that don't fit a
/// plain copyWith).
class ZoomContextInspector extends ConsumerWidget {
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
    this.placementGeometry,
    this.onPlacementPreview,
    this.onPlacementCommit,
    this.isDevice = false,
    this.videoPath = '',
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

  /// The composed-canvas geometry (wallpaper + padding + bezel + screen)
  /// resolved by `playback_screen` exactly as the live canvas renders it.
  /// When null (video not yet measured / catalog still loading) the picker
  /// falls back to the bare-video canvas (canvas == video, no wallpaper
  /// layer / device bezel), which the magnify-in-place box math degrades to
  /// cleanly.
  final ZoomPlacementGeometry? placementGeometry;

  /// Live placement preview: fires for every drag-update with the
  /// in-flight rect, so the canvas can live-preview the framing.
  final ValueChanged<Rect>? onPlacementPreview;

  /// Placement commit: fires once on drag release with the final
  /// rect, so the editor can persist it via `updateZoomAt`.
  final ValueChanged<Rect>? onPlacementCommit;

  /// True for iPhone/iPad recordings captured over USB. These have no
  /// cursor, so the cursor-follow controls are hidden, manual placement is
  /// always offered, and the placement note explains auto-zoom is off.
  final bool isDevice;

  /// Source video path, used to extract the screen frame shown behind the
  /// placement box at the zoom's start time. Empty ⇒ no preview.
  final String videoPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showPlacement =
        (isDevice || !zoom.followCursor) && !videoSize.isEmpty;
    final ui.Image? placementFrame = showPlacement
        ? _watchPlacementFrame(ref)
        : null;
    return _ZoomInspectorScaffold(
      header: _Header(
        icon: Icons.zoom_in,
        title: 'Zoom $zoomNumber',
        subtitle: _rangeLabel(zoom),
        onClose: onClose,
      ),
      children: [
        if (showPlacement) ...[
          const Text(
            'Placement',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isDevice
                ? 'Auto-zoom and cursor-follow are not available for '
                      'iPhone/iPad recordings — position the zoom manually.'
                : 'Drag to set the zoom focal.',
            style: const TextStyle(color: kInspectorMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          // Real composed-canvas wiring: the geometry, wallpaper and
          // (optional) device layout/bezel come from `playback_screen`,
          // resolved the SAME way the live canvas renders, so the picker
          // box matches the render. When the geometry isn't ready yet
          // (video not measured / catalog loading), degrade to the
          // bare-video canvas (canvas == video, no wallpaper layer / no
          // bezel) — the magnify-in-place box math reduces to the old
          // bare-video behavior there.
          ZoomPlacementPicker(
            videoSize: videoSize,
            canvasSize: placementGeometry?.canvasSize ?? videoSize,
            videoRect:
                placementGeometry?.videoRect ?? (Offset.zero & videoSize),
            // Null category ⇒ no wallpaper (render draws none); the
            // picker shows a neutral backdrop to match. The bare-video
            // fallback (no geometry yet) is also null → neutral.
            wallpaperCategory: placementGeometry?.wallpaperCategory,
            wallpaperIndex: placementGeometry?.wallpaperIndex ?? 0,
            wallpaperSolidColor: placementGeometry?.wallpaperSolidColor,
            deviceLayout: placementGeometry?.deviceLayout,
            bezel: placementGeometry?.bezel,
            rect: zoom.rect,
            zoomLevel: zoom.zoomLevel,
            onPreview: (r) => onPlacementPreview?.call(r),
            onCommit: (r) => onPlacementCommit?.call(r),
            screenFrame: placementFrame,
          ),
          const InspectorSectionDivider(),
        ],
        InspectorSlider(
          label: 'Zoom level',
          value: zoom.zoomLevel,
          min: 1,
          max: 5,
          onChanged: (v) => onChanged(zoom.copyWith(zoomLevel: v)),
          onReset: () => onChanged(zoom.copyWith(zoomLevel: 2.0)),
          canReset: zoom.zoomLevel != 2.0,
          subtitle: '${zoom.zoomLevel.toStringAsFixed(1)}×',
        ),
        const InspectorSectionDivider(),
        InspectorToggle(
          label: '3D tilt',
          subtitle: 'Perspective lean as the zoom plays',
          value: zoom.tilt.is3D,
          onChanged: (on) => onChanged(
            zoom.copyWith(
              tilt: on
                  ? (zoom.tilt.is3D
                        ? zoom.tilt
                        : const Tilt3D(style: ZoomTiltStyle.subtle))
                  : const Tilt3D(),
            ),
          ),
        ),
        if (zoom.tilt.is3D) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in const [
                (ZoomTiltStyle.subtle, 'Subtle'),
                (ZoomTiltStyle.dramatic, 'Dramatic'),
              ])
                InspectorChip(
                  label: entry.$2,
                  selected: zoom.tilt.style == entry.$1,
                  dense: true,
                  onTap: () => onChanged(
                    zoom.copyWith(tilt: zoom.tilt.copyWith(style: entry.$1)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          InspectorCollapsible(
            title: 'Advanced',
            child: Column(
              children: [
                InspectorSlider(
                  label: 'Tilt X',
                  value: zoom.tilt.manualAngleX ?? 0,
                  min: -20,
                  max: 20,
                  onChanged: (v) => onChanged(
                    zoom.copyWith(tilt: zoom.tilt.copyWith(manualAngleX: v)),
                  ),
                  onReset: () => onChanged(
                    zoom.copyWith(
                      tilt: Tilt3D(
                        style: zoom.tilt.style,
                        manualAngleY: zoom.tilt.manualAngleY,
                      ),
                    ),
                  ),
                  canReset: zoom.tilt.manualAngleX != null,
                  subtitle: zoom.tilt.manualAngleX == null
                      ? 'Auto'
                      : '${zoom.tilt.manualAngleX!.toStringAsFixed(0)}°',
                ),
                const SizedBox(height: 16),
                InspectorSlider(
                  label: 'Tilt Y',
                  value: zoom.tilt.manualAngleY ?? 0,
                  min: -20,
                  max: 20,
                  onChanged: (v) => onChanged(
                    zoom.copyWith(tilt: zoom.tilt.copyWith(manualAngleY: v)),
                  ),
                  onReset: () => onChanged(
                    zoom.copyWith(
                      tilt: Tilt3D(
                        style: zoom.tilt.style,
                        manualAngleX: zoom.tilt.manualAngleX,
                      ),
                    ),
                  ),
                  canReset: zoom.tilt.manualAngleY != null,
                  subtitle: zoom.tilt.manualAngleY == null
                      ? 'Auto'
                      : '${zoom.tilt.manualAngleY!.toStringAsFixed(0)}°',
                ),
              ],
            ),
          ),
        ],
        const InspectorSectionDivider(),
        const InspectorSectionLabel('Movement'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in [
              (ZoomMovementKind.none, 'None'),
              (ZoomMovementKind.pushIn, 'Push-in'),
              (ZoomMovementKind.sweep, 'Sweep'),
              // Drift moves the focal — only meaningful for manual
              // (in-place) zooms; it would fight the cursor follow.
              if (!zoom.followCursor) (ZoomMovementKind.drift, 'Drift'),
            ])
              InspectorChip(
                label: entry.$2,
                selected: zoom.movement.kind == entry.$1,
                dense: true,
                onTap: () => onChanged(
                  zoom.copyWith(
                    movement: zoom.movement.copyWith(kind: entry.$1),
                  ),
                ),
              ),
          ],
        ),
        if (zoom.movement.isActive) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in const [
                (ZoomMovementIntensity.subtle, 'Subtle'),
                (ZoomMovementIntensity.dramatic, 'Dramatic'),
              ])
                InspectorChip(
                  label: entry.$2,
                  selected: zoom.movement.intensity == entry.$1,
                  dense: true,
                  onTap: () => onChanged(
                    zoom.copyWith(
                      movement: zoom.movement.copyWith(intensity: entry.$1),
                    ),
                  ),
                ),
            ],
          ),
        ],
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
              zoom.zoomLevel,
              zoom.manualPanBackload,
            ),
            value: zoom.manualPanBackload ?? 1.0,
            min: 0.0,
            max: 3.0,
            onChanged: (v) => onChanged(zoom.copyWith(manualPanBackload: v)),
            onReset: () =>
                onChanged(zoom.copyWith(clearManualPanBackload: true)),
            canReset: zoom.manualPanBackload != null,
          ),
          const InspectorSectionDivider(),
        ],
        if (!isDevice)
          InspectorToggle(
            label: 'Auto-zoom on cursor',
            subtitle:
                'Camera follows the recorded cursor through the '
                'zoom region. Off pins the focal to the zoom\'s '
                'rect center.',
            value: zoom.followCursor,
            onChanged: (v) => onChanged(zoom.copyWith(followCursor: v)),
          ),
        if (!isDevice && zoom.followCursor) ...[
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
            onChanged: (m) => onChanged(zoom.copyWith(followMode: m)),
          ),
          if (zoom.followMode == FollowMode.bounded ||
              zoom.followMode == FollowMode.predictive) ...[
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
              onChanged: (v) => onChanged(zoom.copyWith(deadzoneRatio: v)),
              onReset: () => onChanged(zoom.copyWith(deadzoneRatio: 0.8)),
              canReset: (zoom.deadzoneRatio - 0.8).abs() > 1e-6,
            ),
          ],
          if (zoom.followMode == FollowMode.predictive) ...[
            const SizedBox(height: 16),
            InspectorSlider(
              label: 'Lead time',
              subtitle:
                  '${zoom.predictiveWindow.inMilliseconds} ms — '
                  'how far ahead the camera aims along the cursor\'s '
                  'velocity (anticipatory follow).',
              value: zoom.predictiveWindow.inMilliseconds.toDouble(),
              min: 80,
              max: 250,
              onChanged: (v) => onChanged(
                zoom.copyWith(
                  predictiveWindow: Duration(milliseconds: v.toInt()),
                ),
              ),
              onReset: () => onChanged(
                zoom.copyWith(
                  predictiveWindow: const Duration(milliseconds: 150),
                ),
              ),
              canReset:
                  zoom.predictiveWindow != const Duration(milliseconds: 150),
            ),
          ],
          const SizedBox(height: 24),
          InspectorSlider(
            label: 'Follow duration',
            subtitle:
                '${zoom.followDuration.inMilliseconds} ms for the '
                'camera to settle on a new target',
            value: zoom.followDuration.inMilliseconds.toDouble(),
            min: 100,
            max: 1500,
            onChanged: (v) => onChanged(
              zoom.copyWith(followDuration: Duration(milliseconds: v.toInt())),
            ),
            onReset: () => onChanged(
              zoom.copyWith(followDuration: const Duration(milliseconds: 850)),
            ),
            canReset: zoom.followDuration != const Duration(milliseconds: 850),
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
            subtitle: '${zoom.enterDuration.inMilliseconds} ms ramp-in',
            value: zoom.enterDuration.inMilliseconds.toDouble(),
            min: 0,
            max: 1500,
            onChanged: (v) => onChanged(
              zoom.copyWith(enterDuration: Duration(milliseconds: v.toInt())),
            ),
            onReset: () => onChanged(
              zoom.copyWith(enterDuration: const Duration(milliseconds: 500)),
            ),
            canReset: zoom.enterDuration != const Duration(milliseconds: 500),
          ),
          const SizedBox(height: 24),
          InspectorSlider(
            label: 'Exit duration (debug)',
            subtitle: '${zoom.exitDuration.inMilliseconds} ms ramp-out',
            value: zoom.exitDuration.inMilliseconds.toDouble(),
            min: 0,
            max: 1500,
            onChanged: (v) => onChanged(
              zoom.copyWith(exitDuration: Duration(milliseconds: v.toInt())),
            ),
            onReset: () => onChanged(
              zoom.copyWith(exitDuration: const Duration(milliseconds: 500)),
            ),
            canReset: zoom.exitDuration != const Duration(milliseconds: 500),
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
                const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
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
    );
  }

  /// Watches the extracted screen frame for this zoom's start time, sized to
  /// the placement mini-frame (longest side ~640px, video aspect preserved).
  /// Returns null while loading or on failure — the picker falls back to a
  /// plain background.
  ui.Image? _watchPlacementFrame(WidgetRef ref) {
    if (videoPath.isEmpty || videoSize.isEmpty) return null;
    final aspect = videoSize.width / videoSize.height;
    final int tw, th;
    if (aspect >= 1) {
      tw = 640;
      th = (640 / aspect).round().clamp(1, 4096);
    } else {
      th = 640;
      tw = (640 * aspect).round().clamp(1, 4096);
    }
    return ref
        .watch(
          frameExtractorProvider(
            FrameKey(videoPath, zoom.startTime.inMicroseconds, tw, th),
          ),
        )
        .valueOrNull;
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
    final effective = v ?? ZoomFocalController.manualBackloadForZoom(zoomLevel);
    final n = '${effective.toStringAsFixed(2)}×';
    final feel = (effective - 1.0).abs() < 0.01
        ? 'lock-step'
        : (effective < 1.0 ? 'pan leads' : 'pan lags');
    final src = v == null ? ' (auto)' : '';
    return 'zoom $z · back-load $n$src — $feel';
  }
}

/// Scrollable zoom-inspector body with a solid header bar on top. The header
/// is a normal [Column] child sitting ABOVE the scroll view, so list content
/// can never paint over it (the previous Stack/Clip.none layout let scrolled
/// content bleed up into the header, which read as a floating/transparent
/// bar). A subtle divider fades in under the header once the list is scrolled
/// away from the top, signalling there's more content above.
class _ZoomInspectorScaffold extends StatefulWidget {
  const _ZoomInspectorScaffold({required this.header, required this.children});

  final Widget header;
  final List<Widget> children;

  @override
  State<_ZoomInspectorScaffold> createState() => _ZoomInspectorScaffoldState();
}

class _ZoomInspectorScaffoldState extends State<_ZoomInspectorScaffold> {
  final ScrollController _controller = ScrollController();
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleScroll);
  }

  void _handleScroll() {
    final scrolled = _controller.hasClients && _controller.offset > 1.0;
    if (scrolled != _scrolled) {
      setState(() => _scrolled = scrolled);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleScroll);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header content is inset; the divider below runs edge-to-edge.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: widget.header,
        ),
        // Breathing room between the header and the divider.
        const SizedBox(height: 14),
        // Edge-to-edge divider: hidden at the top, fades in once scrolled.
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 1,
          color: _scrolled ? kInspectorBorder : Colors.transparent,
        ),
        Expanded(
          // Inner padding so list items are inset while the header bar and
          // divider above span the full panel width. Default (hard-edge)
          // clipping keeps list content strictly below the header.
          child: ListView(
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            children: widget.children,
          ),
        ),
      ],
    );
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
                style: const TextStyle(color: kInspectorMuted, fontSize: 12),
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
  const _FollowModeSegmented({required this.mode, required this.onChanged});

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
            Icon(Icons.delete_outline, color: Color(0xFFE57373), size: 18),
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
