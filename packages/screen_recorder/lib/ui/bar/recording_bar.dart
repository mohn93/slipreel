import 'package:flutter/material.dart';

/// The selectable source modes on the bar. `device` is shown but disabled.
enum BarSourceMode { display, window, area, device }

/// The compact floating control bar: close, source modes, disabled A/V
/// placeholders, and a gear menu. Pure presentation — all actions are
/// callbacks; no IO or navigation here.
class RecordingBar extends StatelessWidget {
  const RecordingBar({
    super.key,
    required this.onPickMode,
    required this.onClose,
    required this.onOpenRecents,
    required this.onOpenSettings,
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onClose;
  final VoidCallback onOpenRecents;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // Fills the whole (borderless) window edge-to-edge with the bar colour;
    // the native window rounds its corners via a layer mask and supplies the
    // drop shadow. This avoids depending on Flutter-layer transparency, which
    // renders an opaque black box on a borderless macOS window.
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleButton(
              key: const Key('bar-close'),
              icon: Icons.close,
              tooltip: 'Quit Slipreel',
              onPressed: onClose,
            ),
            const _Divider(),
            _Mode(
              icon: Icons.desktop_windows_outlined,
              label: 'Display',
              onTap: () => onPickMode(BarSourceMode.display),
            ),
            _Mode(
              icon: Icons.web_asset,
              label: 'Window',
              onTap: () => onPickMode(BarSourceMode.window),
            ),
            _Mode(
              icon: Icons.crop_free,
              label: 'Area',
              onTap: () => onPickMode(BarSourceMode.area),
            ),
            const _Mode(
              icon: Icons.phone_iphone,
              label: 'Device',
              disabledTooltip: 'Device capture — coming soon',
            ),
            const _Divider(),
            const _AvPlaceholder(icon: Icons.videocam_off_outlined, label: 'No camera'),
            const _AvPlaceholder(icon: Icons.mic_off_outlined, label: 'No microphone'),
            const _AvPlaceholder(icon: Icons.volume_off_outlined, label: 'No system audio'),
            const _Divider(),
            _GearMenu(
              onOpenRecents: onOpenRecents,
              onOpenSettings: onOpenSettings,
              onQuit: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Gear dropdown — OverlayPortal so items are hit-testable outside the bar
// bounds, and close synchronously (no route/barrier) so tests can chain two
// open-select cycles without an intervening pumpAndSettle.
// ---------------------------------------------------------------------------

class _GearMenu extends StatefulWidget {
  const _GearMenu({
    required this.onOpenRecents,
    required this.onOpenSettings,
    required this.onQuit,
  });

  final VoidCallback onOpenRecents;
  final VoidCallback onOpenSettings;
  final VoidCallback onQuit;

  @override
  State<_GearMenu> createState() => _GearMenuState();
}

class _GearMenuState extends State<_GearMenu> {
  final _controller = OverlayPortalController();
  final _layerLink = LayerLink();

  void _open() => _controller.show();
  void _close() => _controller.hide();
  void _toggle() {
    if (_controller.isShowing) {
      _close();
    } else {
      _open();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (BuildContext ctx) {
        return CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          child: Align(
            alignment: Alignment.topRight,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              color: const Color(0xFF3A3A3E),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _GearItem(
                      label: 'Recent recordings',
                      onTap: () {
                        _close();
                        widget.onOpenRecents();
                      },
                    ),
                    _GearItem(
                      label: 'Settings',
                      onTap: () {
                        _close();
                        widget.onOpenSettings();
                      },
                    ),
                    const Divider(height: 1, color: Color(0xFF55555A)),
                    _GearItem(
                      label: 'Quit Slipreel',
                      onTap: () {
                        _close();
                        widget.onQuit();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: Tooltip(
          message: 'More',
          child: InkWell(
            key: const Key('bar-gear'),
            onTap: _toggle,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: const Icon(
                  Icons.settings_outlined,
                  color: Color(0xFFD6D6DA),
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GearItem extends StatelessWidget {
  const _GearItem({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFFE9E9EC)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal layout helpers
// ---------------------------------------------------------------------------

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

class _Mode extends StatelessWidget {
  const _Mode({
    required this.icon,
    required this.label,
    this.onTap,
    this.disabledTooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? disabledTooltip;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled ? const Color(0xFF6E6E76) : const Color(0xFFE9E9EC);
    final body = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
    if (disabled && disabledTooltip != null) {
      return Tooltip(message: disabledTooltip!, child: body);
    }
    return body;
  }
}

class _AvPlaceholder extends StatelessWidget {
  const _AvPlaceholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label — coming soon',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF6E6E76)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E76))),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 16, color: const Color(0xFFE9E9EC)),
        ),
      ),
    );
  }
}
