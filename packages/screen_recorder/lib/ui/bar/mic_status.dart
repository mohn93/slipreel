import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'mic_level_meter.dart';

/// Shows the live [MicLevelMeter] for a selected mic, or an amber warning
/// triangle when the selected input has a problem. Two cases warn:
///  - the native monitor emits a negative sentinel (failed to start / engine
///    error / the selected device is no longer available);
///  - the input taps fine but emits a *literal* zero level for a sustained
///    window — a dead or virtual-silent input (e.g. a loopback cable with
///    nothing routed). A real mic's noise floor never sits at exact zero, so a
///    merely quiet mic never warns.
class MicStatus extends StatefulWidget {
  const MicStatus({super.key, required this.levelStream});

  final Stream<double> levelStream;

  @override
  State<MicStatus> createState() => _MicStatusState();
}

class _MicStatusState extends State<MicStatus> {
  StreamSubscription<double>? _sub;
  Timer? _noSignalTimer;
  bool _problem = false;

  // A real mic's noise floor stays above this even in a silent room; only a
  // dead/virtual-silent input sits at a literal zero. Held for the window
  // below, that reads as "no signal" and warns.
  static const double _kNoSignalEpsilon = 0.001;
  static const Duration _kNoSignalWindow = Duration(milliseconds: 2500);

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
      _cancelNoSignalTimer();
      _problem = false;
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.levelStream.listen(_onLevel);
  }

  void _onLevel(double v) {
    if (!mounted) return;
    if (v < 0) {
      // Native problem sentinel: failed to start / engine error / the selected
      // device is unavailable.
      _cancelNoSignalTimer();
      _setProblem(true);
    } else if (v < _kNoSignalEpsilon) {
      // Literal silence — arm the no-signal countdown once. A real mic never
      // sits here, so this only trips on a dead/virtual-silent input.
      if (!_problem) _armNoSignalTimer();
    } else {
      // Real signal present — cancel the countdown and clear any warning.
      _cancelNoSignalTimer();
      _setProblem(false);
    }
  }

  void _armNoSignalTimer() {
    _noSignalTimer ??= Timer(_kNoSignalWindow, () {
      _noSignalTimer = null;
      _setProblem(true);
    });
  }

  void _cancelNoSignalTimer() {
    _noSignalTimer?.cancel();
    _noSignalTimer = null;
  }

  void _setProblem(bool problem) {
    if (problem != _problem && mounted) setState(() => _problem = problem);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cancelNoSignalTimer();
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
