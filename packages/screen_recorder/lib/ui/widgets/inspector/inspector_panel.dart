import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/camera_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/slice_editor.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/animation_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/audio_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/background_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/camera_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/device_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/captions_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/cursor_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/shortcuts_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';
import '../animated_indicator_bar.dart';
import '../springy_icon_button.dart';

/// Right-hand inspector for the playback editor.
///
/// Two display modes:
///   - Format mode (no selection): vertical icon rail on the left
///     plus the chosen tab on the right (Background, Cursor, etc.).
///   - Context mode: when [selection] is non-null, the rail is
///     replaced by a "Back" pill and the right pane shows a
///     properties view specific to the selected timeline element.
///
/// Either mode keeps the same outer width so the preview area
/// doesn't reflow when selection toggles.
class InspectorPanel extends StatefulWidget {
  const InspectorPanel({
    super.key,
    this.width = 380,
    this.initialTab = InspectorTab.background,
    this.selection,
    this.zoomRegions = const [],
    this.clipDuration = Duration.zero,
    this.onZoomChanged,
    this.onZoomDeleted,
    this.onSelectionCleared,
    this.onSliceRemoved,
    this.canHideCursor = false,
    this.hasKeystrokeData = false,
    this.isDevice = false,
    this.hasCamera = false,
    required this.curveLibrary,
    this.videoSize = Size.zero,
    this.videoPath = '',
    this.placementGeometry,
    this.onPlacementPreview,
    this.onPlacementCommit,
    this.cameraRegions = const [],
    this.cameraCanvasAspect = 16 / 9,
    this.cameraOriginalAspect = 1.0,
    this.onCameraChanged,
    this.onCameraDeleted,
  });

  final double width;
  final InspectorTab initialTab;

  /// Whether hiding the cursor is supported for the current recording.
  /// When false the cursor tab's "Hide cursor" toggle is rendered
  /// disabled. Depends on the cursor recording (a session input), not
  /// on persisted editor state, so it can't come from the notifier.
  final bool canHideCursor;

  /// Whether the recording has any keystroke data captured. When false
  /// the Shortcuts tab toggle is disabled with an explanation.
  final bool hasKeystrokeData;

  /// True for iPhone/iPad recordings captured over USB. Such recordings
  /// carry no cursor / click / keystroke data, so the Cursor and Shortcuts
  /// tabs show a "not available" note instead of their controls.
  final bool isDevice;

  /// Whether this recording has a camera sidecar (enables the Camera tab's
  /// real controls; otherwise the tab shows a placeholder).
  final bool hasCamera;

  /// Persistence for user-saved curves shown in the curve editor's
  /// Library row. Required so the inspector doesn't conjure its own
  /// instance and lose entries between rebuilds.
  final CurveLibrary curveLibrary;

  /// What's currently selected on the timeline. When non-null, the
  /// inspector enters context mode. Null returns to tab mode.
  final TimelineSelection? selection;

  /// All zoom regions, indexed by [ZoomSelected.index]. The context
  /// inspector reads from this directly so the existing zoom inspector
  /// flow stays untouched.
  final List<ZoomRegion> zoomRegions;

  /// Total clip duration, displayed in the Clip context header.
  final Duration clipDuration;

  /// Mutate a zoom region (zoom level, enter/exit duration).
  final void Function(int index, ZoomRegion next)? onZoomChanged;

  /// Delete a zoom region.
  final void Function(int index)? onZoomDeleted;

  /// User asked to leave context mode (X button).
  final VoidCallback? onSelectionCleared;

  /// Fires BEFORE the controller drops the slice, so the parent can
  /// migrate its [_selectedSliceIndex] via [decrementSelectionOnRemoval]
  /// before the index becomes stale.
  final ValueChanged<int>? onSliceRemoved;

  /// Video frame size; passed to `ZoomContextInspector` so the
  /// placement picker can render and compute coordinates.
  final Size videoSize;

  /// Source video path; passed to `ZoomContextInspector` so the placement
  /// picker can show a screen-frame preview behind the box.
  final String videoPath;

  /// The composed-canvas geometry (wallpaper + padding + bezel + screen) for
  /// the current frame, resolved by `playback_screen`; forwarded to the zoom
  /// placement picker so the box matches the live canvas.
  final ZoomPlacementGeometry? placementGeometry;

  /// Live placement preview callback for the zoom context.
  final ValueChanged<Rect>? onPlacementPreview;

  /// Placement commit callback for the zoom context.
  final ValueChanged<Rect>? onPlacementCommit;

  /// Camera regions, indexed by [CameraSelected.index].
  final List<CameraRegion> cameraRegions;

  /// Output-canvas aspect (w/h) and the camera source aspect — used by the
  /// Camera tab's Position grid to keep its anchors fully in view.
  final double cameraCanvasAspect;
  final double cameraOriginalAspect;

  /// Mutate a camera region (size, etc.).
  final void Function(int index, CameraRegion next)? onCameraChanged;

  /// Delete a camera region.
  final void Function(int index)? onCameraDeleted;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  late InspectorTab _selected = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    return Container(
      width: widget.width,
      decoration: const BoxDecoration(
        color: kInspectorBg,
        border: Border(left: BorderSide(color: Color(0xFF14141C), width: 1)),
      ),
      child: selection == null ? _formatMode() : _contextMode(selection),
    );
  }

  Widget _formatMode() {
    // The Device tab only applies to device captures; if it ended up selected
    // for a non-device recording, fall back to Background.
    final selected = (_selected == InspectorTab.device && !widget.isDevice)
        ? InspectorTab.background
        : _selected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TipAnchor(
          tipId: TipId.editorInspector,
          child: _Rail(
            selected: selected,
            isDevice: widget.isDevice,
            onSelect: (t) => setState(() => _selected = t),
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: context.palette.dividerSubtle,
        ),
        Expanded(child: _formatContent(selected)),
      ],
    );
  }

  Widget _formatContent(InspectorTab selected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: switch (selected) {
        InspectorTab.background => BackgroundTab(videoSize: widget.videoSize),
        InspectorTab.device => DeviceTab(recordingSize: widget.videoSize),
        InspectorTab.cursor => CursorTab(
            canHideCursor: widget.canHideCursor,
            isDevice: widget.isDevice,
          ),
        InspectorTab.camera => CameraTab(hasCamera: widget.hasCamera),
        InspectorTab.captions => CaptionsTab(videoPath: widget.videoPath),
        InspectorTab.audio => const AudioTab(),
        InspectorTab.shortcuts => ShortcutsTab(
            hasKeystrokeData: widget.hasKeystrokeData,
            isDevice: widget.isDevice,
          ),
        InspectorTab.animation => AnimationTab(library: widget.curveLibrary),
      },
    );
  }

  Widget _contextMode(TimelineSelection selection) {
    return switch (selection) {
      // Zoom manages its own insets so its header bar + scroll divider can run
      // edge-to-edge across the full panel width.
      ZoomSelected(:final index) => _zoomContext(index),
      // Slice does the same: its scaffold owns the insets so the header +
      // scroll divider span the full panel width and the scroll body clips
      // below the header.
      SliceSelected(:final index) => _sliceContext(index),
      CameraSelected(:final index) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: _cameraContext(index),
        ),
    };
  }

  Widget _zoomContext(int index) {
    if (index < 0 || index >= widget.zoomRegions.length) {
      // Selection points to a zoom that no longer exists (deleted
      // mid-flight). Bail to format mode safely.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onSelectionCleared?.call(),
      );
      return const SizedBox.shrink();
    }
    final zoom = widget.zoomRegions[index];
    return ZoomContextInspector(
      zoom: zoom,
      zoomNumber: index + 1,
      onChanged: (next) => widget.onZoomChanged?.call(index, next),
      onDelete: () => widget.onZoomDeleted?.call(index),
      onClose: () => widget.onSelectionCleared?.call(),
      curveLibrary: widget.curveLibrary,
      onCurveOverrideChanged: (curve) {
        final next = curve == null
            ? zoom.copyWith(clearRampCurveOverride: true)
            : zoom.copyWith(rampCurveOverride: curve);
        widget.onZoomChanged?.call(index, next);
      },
      videoSize: widget.videoSize,
      placementGeometry: widget.placementGeometry,
      onPlacementPreview: widget.onPlacementPreview,
      onPlacementCommit: widget.onPlacementCommit,
      isDevice: widget.isDevice,
      videoPath: widget.videoPath,
    );
  }

  Widget _sliceContext(int index) {
    return SliceEditor(
      sliceIndex: index,
      onClose: () => widget.onSelectionCleared?.call(),
      onRemove: widget.onSliceRemoved,
    );
  }

  Widget _cameraContext(int index) {
    if (index < 0 || index >= widget.cameraRegions.length) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onSelectionCleared?.call(),
      );
      return const SizedBox.shrink();
    }
    final region = widget.cameraRegions[index];
    return CameraContextInspector(
      region: region,
      regionNumber: index + 1,
      canvasAspect: widget.cameraCanvasAspect,
      originalAspect: widget.cameraOriginalAspect,
      onChanged: (next) => widget.onCameraChanged?.call(index, next),
      onDelete: () => widget.onCameraDeleted?.call(index),
      onClose: () => widget.onSelectionCleared?.call(),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.selected,
    required this.isDevice,
    required this.onSelect,
  });
  final InspectorTab selected;
  final bool isDevice;
  final ValueChanged<InspectorTab> onSelect;

  @override
  Widget build(BuildContext context) {
    const railWidth = 56.0;
    const railVerticalPad = 12.0;
    const itemHeight = 40.0;
    const itemGap = 8.0;

    // The Device tab is hidden for screen recordings.
    final tabs = visibleInspectorTabs(isDevice: isDevice);
    final selectedIndex = tabs.indexOf(selected);

    return SizedBox(
      width: railWidth,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: railVerticalPad),
        child: Stack(
          children: [
            AnimatedIndicatorBar(
              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
              itemCount: tabs.length,
              itemHeight: itemHeight,
              itemGap: itemGap,
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in tabs) ...[
                    SpringyIconButton(
                      icon: t.icon,
                      tooltip:
                          t.isEnabled ? t.label : '${t.label} — coming soon',
                      isActive: t == selected,
                      isEnabled: t.isEnabled,
                      onTap: () => onSelect(t),
                      size: itemHeight,
                    ),
                    if (t != tabs.last) const SizedBox(height: itemGap),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// _ClipLocalState removed — clip-level fields (playbackSpeed,
// fadeIn, fadeOut) moved into EditorProjectState via P2-8 bugfix
// (review bug #6). Inspector now reads them via ref.watch on the
// editor notifier so the values persist across rebuilds and on disk.
