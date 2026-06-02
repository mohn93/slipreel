import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/slice_editor.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/animation_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/audio_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/background_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/camera_tab.dart';
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
    required this.curveLibrary,
    this.videoSize = Size.zero,
    this.onPlacementPreview,
    this.onPlacementCommit,
  });

  final double width;
  final InspectorTab initialTab;

  /// Whether hiding the cursor is supported for the current recording.
  /// When false the cursor tab's "Hide cursor" toggle is rendered
  /// disabled. Depends on the cursor recording (a session input), not
  /// on persisted editor state, so it can't come from the notifier.
  final bool canHideCursor;

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

  /// Live placement preview callback for the zoom context.
  final ValueChanged<Rect>? onPlacementPreview;

  /// Placement commit callback for the zoom context.
  final ValueChanged<Rect>? onPlacementCommit;

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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TipAnchor(
          tipId: TipId.editorInspector,
          child: _Rail(
            selected: _selected,
            onSelect: (t) => setState(() => _selected = t),
          ),
        ),
        Expanded(child: _formatContent()),
      ],
    );
  }

  Widget _formatContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: switch (_selected) {
        InspectorTab.background => const BackgroundTab(),
        InspectorTab.cursor =>
            CursorTab(canHideCursor: widget.canHideCursor),
        InspectorTab.camera => const CameraTab(),
        InspectorTab.captions => const CaptionsTab(),
        InspectorTab.audio => const AudioTab(),
        InspectorTab.shortcuts => const ShortcutsTab(),
        InspectorTab.animation => AnimationTab(library: widget.curveLibrary),
      },
    );
  }

  Widget _contextMode(TimelineSelection selection) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: switch (selection) {
        SliceSelected(:final index) => _sliceContext(index),
        ZoomSelected(:final index) => _zoomContext(index),
      },
    );
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
      onPlacementPreview: widget.onPlacementPreview,
      onPlacementCommit: widget.onPlacementCommit,
    );
  }

  Widget _sliceContext(int index) {
    return SliceEditor(
      sliceIndex: index,
      onClose: () => widget.onSelectionCleared?.call(),
      onRemove: widget.onSliceRemoved,
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.onSelect});
  final InspectorTab selected;
  final ValueChanged<InspectorTab> onSelect;

  @override
  Widget build(BuildContext context) {
    const railWidth = 56.0;
    const railVerticalPad = 12.0;
    const itemHeight = 40.0;
    const itemGap = 8.0;

    return SizedBox(
      width: railWidth,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: railVerticalPad),
        child: Stack(
          children: [
            AnimatedIndicatorBar(
              selectedIndex: InspectorTab.values.indexOf(selected),
              itemCount: InspectorTab.values.length,
              itemHeight: itemHeight,
              itemGap: itemGap,
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in InspectorTab.values) ...[
                    SpringyIconButton(
                      icon: t.icon,
                      tooltip:
                          t.isEnabled ? t.label : '${t.label} — coming soon',
                      isActive: t == selected,
                      isEnabled: t.isEnabled,
                      onTap: () => onSelect(t),
                      size: itemHeight,
                    ),
                    if (t != InspectorTab.values.last)
                      const SizedBox(height: itemGap),
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
