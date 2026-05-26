import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'mic_level_meter.dart';

/// Shows the live [MicLevelMeter] for a selected mic, or an amber warning
/// triangle when the input looks broken:
///  - a negative sentinel from the native monitor (failed to start / engine
///    error on the device), or
///  - prolonged (near-)digital silence, meaning the input isn't delivering
///    audio (e.g. a virtual/aggregate device with nothing routed to it).
/// The warning springs in horizontally. A working mic's faint noise floor sits
/// above [_eps], so a quiet room does not trip the silence warning.
class MicStatus extends StatefulWidget {
  const MicStatus({
    super.key,
    required this.levelStream,
    this.silenceTimeout = const Duration(seconds: 3),
  });

  final Stream<double> levelStream;
  final Duration silenceTimeout;

  @override
  State<MicStatus> createState() => _MicStatusState();
}

class _MicStatusState extends State<MicStatus> {
  StreamSubscription<double>? _sub;
  Timer? _silence;
  bool _problem = false;

  static const double _eps = 0.03;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(MicStatus old) {
    super.didUpdateWidget(old);
    if (old.levelStream != widget.levelStream) {
      _sub?.cancel();
      _silence?.cancel();
      _silence = null;
      _problem = false;
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.levelStream.listen((v) {
      if (!mounted) return;
      if (v < 0) {
        // Native problem sentinel (failed to start / engine error).
        _silence?.cancel();
        _silence = null;
        if (!_problem) setState(() => _problem = true);
        return;
      }
      if (v > _eps) {
        _silence?.cancel();
        _silence = null;
        if (_problem) setState(() => _problem = false);
      } else {
        // Near silence: arm a one-shot timer on the first quiet sample; further
        // quiet samples don't reset it, so it fires once the input stays silent.
        _silence ??= Timer(widget.silenceTimeout, () {
          if (mounted && !_problem) setState(() => _problem = true);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _silence?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _problem
        ? const _MicWarning()
        : MicLevelMeter(levelStream: widget.levelStream);
  }
}

/// Amber warning triangle that fades in and then continuously wiggles
/// horizontally in a slow, springy sway.
class _MicWarning extends StatefulWidget {
  const _MicWarning();

  @override
  State<_MicWarning> createState() => _MicWarningState();
}

class _MicWarningState extends State<_MicWarning>
    with SingleTickerProviderStateMixin {
  // Slow back-and-forth sway. reverse:true so it eases out at each extreme,
  // giving the gentle spring feel.
  late final AnimationController _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sway = CurvedAnimation(parent: _wiggle, curve: Curves.easeInOut);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      builder: (_, fade, child) => Opacity(opacity: fade, child: child),
      child: AnimatedBuilder(
        animation: sway,
        builder: (_, child) => Transform.translate(
          // -4..+4 px horizontal sway, eased at the extremes.
          offset: Offset((sway.value * 2 - 1) * 4, 0),
          child: child,
        ),
        child: const Center(
          child: Icon(
            LucideIcons.triangleAlert,
            key: Key('mic-warning'),
            size: 13,
            color: Color(0xFFF5A623), // amber
          ),
        ),
      ),
    );
  }
}
