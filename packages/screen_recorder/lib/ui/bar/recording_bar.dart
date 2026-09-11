import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../onboarding/tip_anchor.dart';
import '../../onboarding/tips_controller.dart';
import 'mic_status.dart';
import 'spring_hover_button.dart';

/// The selectable source modes on the bar. `device` is shown but disabled.
enum BarSourceMode { display, window, area, device }

/// Shared height for the grouped controls. The native bar remains 68 points
/// high, leaving a calm 7-point inset around the interactive row.
const double _kBarButtonHeight = 48;
const double _kInputButtonWidth = 46;

/// The compact floating control bar: primary capture actions, compact input
/// status controls, and a more button that opens a NATIVE menu. There are
/// intentionally no Flutter Tooltips/dropdowns here — Flutter overlays cannot
/// escape the tiny borderless window and would clip. Pure presentation; all
/// actions are callbacks.
class RecordingBar extends StatelessWidget {
  const RecordingBar({
    super.key,
    required this.onPickMode,
    required this.onGearTap,
    required this.onDragStart,
    this.microphone,
    required this.onMicTap,
    this.systemAudio,
    required this.onSystemAudioTap,
    this.camera,
    required this.onCameraTap,
    this.contentKey,
    this.micLevelStream,
    this.micMenuLoading = false,
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onGearTap;

  /// Fired when the user begins dragging a non-button area — used to start a
  /// native window drag so the borderless bar can be repositioned.
  final VoidCallback onDragStart;

  /// Current microphone selection (null = off). Renders the mic control state.
  final MicrophoneConfig? microphone;

  /// Fired when the mic control is tapped (opens the native mic menu).
  final VoidCallback onMicTap;

  /// Current system-audio selection (null = off).
  final SystemAudioConfig? systemAudio;

  /// Fired when the system-audio control is tapped (opens the native menu).
  final VoidCallback onSystemAudioTap;

  /// Current camera selection (null = off).
  final CameraConfig? camera;

  /// Fired when the camera control is tapped (opens the native camera menu).
  final VoidCallback onCameraTap;

  /// Attached to the inner content [Row] so the host can measure its intrinsic
  /// width and resize the (variable-width) bar window to hug the content.
  final Key? contentKey;

  /// Live mic level (0..1) stream; when non-null a meter is shown under the mic
  /// control. Null when not monitoring.
  final Stream<double>? micLevelStream;

  /// True while the native microphone device menu is being prepared/opened.
  final bool micMenuLoading;

  @override
  Widget build(BuildContext context) {
    // Fills the whole (borderless) window edge-to-edge with the bar colour;
    // the native window rounds its corners via a layer mask and supplies the
    // drop shadow. The pan gesture lets the user drag the borderless window
    // from any non-button area (buttons still receive their taps).
    return GestureDetector(
      onPanStart: (_) => onDragStart(),
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFF2C2C30),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        // The borderless bar window is sized to the row's intrinsic width by
        // `_syncBarSize` (RecordingBarScreen). On the first frame(s) — before that
        // measurement resizes the window — the incoming width can be narrower than
        // the content, which made a plain `Center > Row` overflow. OverflowBox
        // lets the row take its intrinsic width (what _syncBarSize measures
        // anyway) without throwing, while keeping it centred once the window fits.
        child: OverflowBox(
          alignment: Alignment.center,
          minWidth: 0,
          maxWidth: double.infinity,
          child: Row(
            key: contentKey,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _GroupLabel('Record'),
              TipAnchor(
                tipId: TipId.barModePicker,
                dimBackdrop: false,
                child: _Mode(
                  icon: LucideIcons.monitor,
                  label: 'Screen',
                  onTap: () => onPickMode(BarSourceMode.display),
                ),
              ),
              _Mode(
                icon: LucideIcons.appWindowMac,
                label: 'Window',
                onTap: () => onPickMode(BarSourceMode.window),
              ),
              _Mode(
                icon: LucideIcons.scan,
                label: 'Area',
                onTap: () => onPickMode(BarSourceMode.area),
              ),
              _Mode(
                icon: LucideIcons.smartphone,
                label: 'Device',
                onTap: () => onPickMode(BarSourceMode.device),
              ),
              const _Divider(),
              _CameraControl(camera: camera, onTap: onCameraTap),
              _MicControl(
                microphone: microphone,
                onTap: onMicTap,
                levelStream: micLevelStream,
                menuLoading: micMenuLoading,
              ),
              _SystemAudioControl(
                systemAudio: systemAudio,
                onTap: onSystemAudioTap,
              ),
              const _Divider(),
              _GearButton(onTap: onGearTap),
            ],
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 34,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: Colors.white.withValues(alpha: 0.10),
  );
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 7, right: 5),
    child: Text(
      label,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.46),
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Mode extends StatelessWidget {
  const _Mode({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled ? const Color(0xFF6E6E76) : const Color(0xFFDCDCE1);
    return SpringHoverButton(
      onTap: onTap,
      child: SizedBox(
        // Lucide's icon glyphs carry wider intrinsic metrics than their visual
        // 18-point box, so leave enough room for the longest labels at the
        // app's inherited desktop text scale.
        width: label == 'Area' ? 70 : 84,
        height: _kBarButtonHeight,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact microphone status button. The checked device remains visible in
/// the native menu; here a status pin and the retained live meter provide the
/// at-a-glance confidence needed before recording.
class _MicControl extends StatefulWidget {
  const _MicControl({
    required this.microphone,
    required this.onTap,
    this.levelStream,
    required this.menuLoading,
  });

  final MicrophoneConfig? microphone;
  final VoidCallback onTap;
  final Stream<double>? levelStream;
  final bool menuLoading;

  @override
  State<_MicControl> createState() => _MicControlState();
}

class _MicControlState extends State<_MicControl> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.microphone != null;
    final label = on
        ? 'Microphone: ${widget.microphone!.deviceLabel}'
        : 'Microphone off';
    final active = on || _hover;
    return Semantics(
      button: true,
      label: label,
      child: SpringHoverButton(
        key: const Key('bar-mic'),
        onTap: widget.onTap,
        onHoverChanged: (h) => setState(() => _hover = h),
        child: SizedBox(
          width: _kInputButtonWidth,
          height: _kBarButtonHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: active ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                builder: (context, t, _) => Icon(
                  on ? LucideIcons.mic : LucideIcons.micOff,
                  size: 20,
                  color: Color.lerp(
                    const Color(0xFF6E6E76),
                    const Color(0xFFE9E9EC),
                    t,
                  ),
                ),
              ),
              if (widget.menuLoading)
                const Positioned(
                  right: 5,
                  top: 5,
                  child: SizedBox(
                    key: Key('mic-menu-loading'),
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.4,
                      color: Color(0xFFAFAFB6),
                      semanticsLabel: 'Loading microphones',
                    ),
                  ),
                )
              else
                Positioned(right: 6, bottom: 7, child: _StatusDot(on: on)),
              if (widget.levelStream != null)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 4,
                  child: MicStatus(levelStream: widget.levelStream!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact system-audio status button.
class _SystemAudioControl extends StatefulWidget {
  const _SystemAudioControl({required this.systemAudio, required this.onTap});

  final SystemAudioConfig? systemAudio;
  final VoidCallback onTap;

  @override
  State<_SystemAudioControl> createState() => _SystemAudioControlState();
}

class _SystemAudioControlState extends State<_SystemAudioControl> {
  bool _hover = false;

  String get _label {
    final cfg = widget.systemAudio;
    if (cfg == null) return 'No system audio';
    switch (cfg.mode) {
      case SystemAudioMode.allApps:
        return 'System audio';
      case SystemAudioMode.selectedApps:
        final n = cfg.bundleIds.length;
        return n == 1 ? '1 app' : '$n apps';
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.systemAudio != null;
    final active = on || _hover;
    return Semantics(
      button: true,
      label: on ? _label : 'System audio off',
      child: SpringHoverButton(
        key: const Key('bar-system-audio'),
        onTap: widget.onTap,
        onHoverChanged: (h) => setState(() => _hover = h),
        child: SizedBox(
          width: _kInputButtonWidth,
          height: _kBarButtonHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: active ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                builder: (context, t, _) => Icon(
                  on ? LucideIcons.volume2 : LucideIcons.volumeOff,
                  size: 20,
                  color: Color.lerp(
                    const Color(0xFF6E6E76),
                    const Color(0xFFE9E9EC),
                    t,
                  ),
                ),
              ),
              Positioned(right: 6, bottom: 7, child: _StatusDot(on: on)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Test-only public wrapper around the private [_SystemAudioControl].
@visibleForTesting
class SystemAudioControlForTest extends StatelessWidget {
  const SystemAudioControlForTest({
    super.key,
    this.systemAudio,
    required this.onTap,
  });
  final SystemAudioConfig? systemAudio;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) =>
      _SystemAudioControl(systemAudio: systemAudio, onTap: onTap);
}

/// Compact camera status button.
class _CameraControl extends StatefulWidget {
  const _CameraControl({required this.camera, required this.onTap});

  final CameraConfig? camera;
  final VoidCallback onTap;

  @override
  State<_CameraControl> createState() => _CameraControlState();
}

class _CameraControlState extends State<_CameraControl> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.camera != null;
    final label = on ? 'Camera: ${widget.camera!.deviceLabel}' : 'Camera off';
    final active = on || _hover;
    return Semantics(
      button: true,
      label: label,
      child: SpringHoverButton(
        key: const Key('bar-camera'),
        onTap: widget.onTap,
        onHoverChanged: (h) => setState(() => _hover = h),
        child: SizedBox(
          width: _kInputButtonWidth,
          height: _kBarButtonHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: active ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                builder: (context, t, _) => Icon(
                  on ? LucideIcons.video : LucideIcons.videoOff,
                  size: 20,
                  color: Color.lerp(
                    const Color(0xFF6E6E76),
                    const Color(0xFFE9E9EC),
                    t,
                  ),
                ),
              ),
              Positioned(right: 6, bottom: 7, child: _StatusDot(on: on)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Test-only public wrapper around the private [_CameraControl].
@visibleForTesting
class CameraControlForTest extends StatelessWidget {
  const CameraControlForTest({super.key, this.camera, required this.onTap});
  final CameraConfig? camera;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) =>
      _CameraControl(camera: camera, onTap: onTap);
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      color: on ? const Color(0xFF62D985) : const Color(0xFF62626B),
      shape: BoxShape.circle,
      boxShadow: on
          ? const [BoxShadow(color: Color(0x2862D985), blurRadius: 4)]
          : null,
    ),
  );
}

class _GearButton extends StatelessWidget {
  const _GearButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Utility actions are deliberately quieter than capture and input state.
    return Semantics(
      button: true,
      label: 'More options',
      child: SpringHoverButton(
        key: const Key('bar-gear'),
        onTap: onTap,
        borderRadius: 11,
        child: const SizedBox(
          width: 46,
          height: _kBarButtonHeight,
          child: Center(
            child: Icon(
              LucideIcons.ellipsis,
              color: Color(0xFF8B8B94),
              size: 21,
            ),
          ),
        ),
      ),
    );
  }
}
