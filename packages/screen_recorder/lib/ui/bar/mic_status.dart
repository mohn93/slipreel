import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'mic_level_meter.dart';

/// Shows the live [MicLevelMeter] for a selected mic, or an amber warning
/// triangle when the native monitor reports a real input problem: a negative
/// sentinel emitted when the monitor fails to start / the audio engine errors
/// on the device. Plain silence (a valid 0 level) is NOT a problem, so a quiet
/// mic never warns.
class MicStatus extends StatefulWidget {
  const MicStatus({super.key, required this.levelStream});

  final Stream<double> levelStream;

  @override
  State<MicStatus> createState() => _MicStatusState();
}

class _MicStatusState extends State<MicStatus> {
  StreamSubscription<double>? _sub;
  bool _problem = false;

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
      _problem = false;
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.levelStream.listen((v) {
      if (!mounted) return;
      // Negative = native problem sentinel (failed to start / engine error).
      // Any valid 0..1 level — including silence — clears it.
      final problem = v < 0;
      if (problem != _problem) setState(() => _problem = problem);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
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
