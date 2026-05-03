import 'package:flutter/material.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/clip_context_inspector.dart';
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
    required this.frameSettings,
    this.width = 380,
    this.initialTab = InspectorTab.background,
    this.selection,
    this.zoomRegions = const [],
    this.clipDuration = Duration.zero,
    this.onZoomChanged,
    this.onZoomDeleted,
    this.onSelectionCleared,
    this.hideCursor = false,
    this.canHideCursor = false,
    this.onHideCursorChanged,
    this.cursorSize = 1.0,
    this.cursorStyle = CursorStyle.modernDark,
    this.cursorClickEffect = CursorClickEffect.ripple,
    this.onCursorSizeChanged,
    this.onCursorStyleChanged,
    this.onCursorClickEffectChanged,
    this.screenAnimationConfig = const ScreenAnimationConfig.preset(
        ScreenAnimationStyle.smooth),
    this.cursorAnimationConfig = const CursorAnimationConfig.preset(
        CursorAnimationStyle.smooth),
    this.motionBlur = 0,
    this.onScreenAnimationConfigChanged,
    this.onCursorAnimationConfigChanged,
    this.onMotionBlurChanged,
    required this.curveLibrary,
  });

  final FrameSettingsProvider frameSettings;
  final double width;
  final InspectorTab initialTab;

  /// Whether the synthetic cursor overlay is currently hidden in the
  /// preview. Controlled from the cursor tab's "Hide cursor" toggle.
  final bool hideCursor;

  /// Whether hiding the cursor is supported for the current recording.
  /// When false the toggle is rendered disabled.
  final bool canHideCursor;

  /// Setter for [hideCursor]. Required for the cursor tab to write
  /// through to the parent's state.
  final ValueChanged<bool>? onHideCursorChanged;

  /// Cursor size multiplier (0.5 – 8.0). Live-applied to the playback
  /// overlay and carried into the export pipeline.
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;
  final ValueChanged<double>? onCursorSizeChanged;
  final ValueChanged<CursorStyle>? onCursorStyleChanged;
  final ValueChanged<CursorClickEffect>? onCursorClickEffectChanged;

  /// Screen + cursor animation configs drive zoom transitions and
  /// focal smoothing on the playback canvas. Each config is either a
  /// preset enum or a user-authored cubic bezier; the animation tab
  /// chooses between them.
  final ScreenAnimationConfig screenAnimationConfig;
  final CursorAnimationConfig cursorAnimationConfig;
  final double motionBlur;
  final ValueChanged<ScreenAnimationConfig>? onScreenAnimationConfigChanged;
  final ValueChanged<CursorAnimationConfig>? onCursorAnimationConfigChanged;
  final ValueChanged<double>? onMotionBlurChanged;

  /// Persistence for user-saved curves shown in the curve editor's
  /// Library row. Required so the inspector doesn't conjure its own
  /// instance and lose entries between rebuilds.
  final CurveLibrary curveLibrary;

  /// What's currently selected on the timeline. When non-null, the
  /// inspector enters context mode. Null returns to tab mode.
  final TimelineSelection? selection;

  /// All zoom regions, indexed by [ZoomSelected.index].
  final List<ZoomRegion> zoomRegions;

  /// Total clip duration, displayed in the Clip context header.
  final Duration clipDuration;

  /// Mutate a zoom region (zoom level, enter/exit duration).
  final void Function(int index, ZoomRegion next)? onZoomChanged;

  /// Delete a zoom region.
  final void Function(int index)? onZoomDeleted;

  /// User asked to leave context mode (X button).
  final VoidCallback? onSelectionCleared;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  late InspectorTab _selected = widget.initialTab;

  // Local state for context-mode controls that don't have a model
  // field yet. Per-zoom values are keyed on the zoom's startTime so
  // the right values come back when re-selecting the same zoom.
  final Map<Duration, _ZoomLocalState> _zoomLocal = {};
  final _ClipLocalState _clipLocal = _ClipLocalState();

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    return Container(
      width: widget.width,
      decoration: const BoxDecoration(
        color: kInspectorBg,
        border: Border(
          left: BorderSide(color: Color(0xFF14141C), width: 1),
        ),
      ),
      child: selection == null
          ? _formatMode()
          : _contextMode(selection),
    );
  }

  Widget _formatMode() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Rail(
          selected: _selected,
          onSelect: (t) => setState(() => _selected = t),
        ),
        Expanded(child: _formatContent()),
      ],
    );
  }

  Widget _formatContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: switch (_selected) {
        InspectorTab.background =>
          BackgroundTab(frameSettings: widget.frameSettings),
        InspectorTab.cursor => CursorTab(
            size: widget.cursorSize,
            onSizeChanged: widget.onCursorSizeChanged ?? (_) {},
            style: widget.cursorStyle,
            onStyleChanged: widget.onCursorStyleChanged ?? (_) {},
            clickEffect: widget.cursorClickEffect,
            onClickEffectChanged:
                widget.onCursorClickEffectChanged ?? (_) {},
            hideCursor: widget.hideCursor,
            canHideCursor: widget.canHideCursor,
            onHideCursorChanged:
                widget.onHideCursorChanged ?? (_) {},
          ),
        InspectorTab.camera => const CameraTab(),
        InspectorTab.captions => const CaptionsTab(),
        InspectorTab.audio => const AudioTab(),
        InspectorTab.shortcuts => const ShortcutsTab(),
        InspectorTab.animation => AnimationTab(
            screenConfig: widget.screenAnimationConfig,
            onScreenConfigChanged: (c) =>
                widget.onScreenAnimationConfigChanged?.call(c),
            cursorConfig: widget.cursorAnimationConfig,
            onCursorConfigChanged: (c) =>
                widget.onCursorAnimationConfigChanged?.call(c),
            motionBlur: widget.motionBlur,
            onMotionBlurChanged: (v) =>
                widget.onMotionBlurChanged?.call(v),
            library: widget.curveLibrary,
          ),
      },
    );
  }

  Widget _contextMode(TimelineSelection selection) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: switch (selection) {
        ClipSelected() => _clipContext(),
        ZoomSelected(:final index) => _zoomContext(index),
      },
    );
  }

  Widget _zoomContext(int index) {
    if (index < 0 || index >= widget.zoomRegions.length) {
      // Selection points to a zoom that no longer exists (deleted
      // mid-flight). Bail to format mode safely.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onSelectionCleared?.call());
      return const SizedBox.shrink();
    }
    final zoom = widget.zoomRegions[index];
    final local =
        _zoomLocal.putIfAbsent(zoom.startTime, () => _ZoomLocalState());
    return ZoomContextInspector(
      zoom: zoom,
      zoomNumber: index + 1,
      onChanged: (next) => widget.onZoomChanged?.call(index, next),
      onDelete: () => widget.onZoomDeleted?.call(index),
      onClose: () => widget.onSelectionCleared?.call(),
      followCursor: local.followCursor,
      onFollowCursorChanged: (v) =>
          setState(() => local.followCursor = v),
      focalMode: local.focalMode,
      onFocalModeChanged: (m) => setState(() => local.focalMode = m),
    );
  }

  Widget _clipContext() {
    return ClipContextInspector(
      clipDuration: widget.clipDuration,
      playbackSpeed: _clipLocal.playbackSpeed,
      onPlaybackSpeedChanged: (v) =>
          setState(() => _clipLocal.playbackSpeed = v),
      fadeIn: _clipLocal.fadeIn,
      fadeOut: _clipLocal.fadeOut,
      onFadeInChanged: (v) => setState(() => _clipLocal.fadeIn = v),
      onFadeOutChanged: (v) => setState(() => _clipLocal.fadeOut = v),
      onClose: () => widget.onSelectionCleared?.call(),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.onSelect});
  final InspectorTab selected;
  final ValueChanged<InspectorTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          for (final t in InspectorTab.values) ...[
            _RailButton(
              tab: t,
              isSelected: t == selected,
              onTap: () => onSelect(t),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.tab,
    required this.isSelected,
    required this.onTap,
  });

  final InspectorTab tab;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? kInspectorAccent : Colors.white60;
    return Tooltip(
      message: tab.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isSelected
                ? kInspectorAccent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(tab.icon, color: color, size: 20),
              if (isSelected)
                const Positioned(
                  top: 6,
                  right: 6,
                  child: _AccentDot(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: kInspectorAccent,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _ZoomLocalState {
  bool followCursor = true;
  FocalMode focalMode = FocalMode.cursor;
}

class _ClipLocalState {
  double playbackSpeed = 1.0;
  double fadeIn = 0;
  double fadeOut = 0;
}
