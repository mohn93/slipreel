import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A thin horizontal mic level meter. The fill springs toward the latest 0..1
/// value from [levelStream]; a peak-hold marker jumps to the max and decays
/// slowly back (like an audio peak meter). Fills the width given by its parent.
class MicLevelMeter extends StatefulWidget {
  const MicLevelMeter({super.key, required this.levelStream, this.height = 5});

  final Stream<double> levelStream;
  final double height;

  @override
  State<MicLevelMeter> createState() => _MicLevelMeterState();
}

class _MicLevelMeterState extends State<MicLevelMeter>
    with SingleTickerProviderStateMixin {
  StreamSubscription<double>? _sub;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  double _target = 0; // latest level from the stream
  double _display = 0; // spring-animated fill position
  double _velocity = 0; // spring velocity
  double _peak = 0; // peak-hold marker position

  // Spring (2nd-order): stiffness + damping tuned for a lively-but-settled feel.
  static const double _stiffness = 240;
  static const double _damping = 16;
  // Peak marker falls this much per second once the level drops below it.
  static const double _peakDecayPerSec = 0.7;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _subscribe();
  }

  @override
  void didUpdateWidget(MicLevelMeter old) {
    super.didUpdateWidget(old);
    if (old.levelStream != widget.levelStream) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.levelStream.listen((l) {
      if (!mounted) return;
      _target = l.isFinite ? l.clamp(0.0, 1.0) : 0.0;
      if (!_ticker.isActive) {
        _lastTick = Duration.zero;
        _ticker.start();
      }
    });
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : math.min(0.05, (elapsed - _lastTick).inMicroseconds / 1e6);
    _lastTick = elapsed;

    // Spring the display toward the target.
    final accel = -_stiffness * (_display - _target) - _damping * _velocity;
    _velocity += accel * dt;
    _display = (_display + _velocity * dt).clamp(0.0, 1.0);

    // Peak hold: snap up to the display, otherwise decay slowly (never below it).
    if (_display >= _peak) {
      _peak = _display;
    } else {
      _peak = math.max(_display, _peak - _peakDecayPerSec * dt);
    }

    setState(() {});

    // Stop ticking once everything has settled at rest, to save cycles.
    final settled = _target < 0.001 &&
        _display < 0.001 &&
        _velocity.abs() < 0.001 &&
        _peak < 0.001;
    if (settled) _ticker.stop();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  Color get _fillColor {
    if (_display >= 0.97) return const Color(0xFFE5484D); // red near clip
    if (_display >= 0.85) return const Color(0xFFF5A623); // amber
    return const Color(0xFF8A8A92); // dim, less-prominent accent
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height / 2),
        child: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: Color(0x14FFFFFF)), // track
            ),
            // Fill (spring-animated). Positioned so it never feeds an ancestor's
            // intrinsic-width pass (avoids a 0/0 NaN under IntrinsicWidth).
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: _display,
                  child: Container(
                    key: const Key('mic-meter-fill'),
                    decoration: BoxDecoration(color: _fillColor),
                  ),
                ),
              ),
            ),
            // Peak-hold marker: a 2pt line sitting at the peak position.
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: _peak.clamp(0.0, 1.0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 2,
                    child: ColoredBox(
                      key: const Key('mic-meter-peak'),
                      color: const Color(0xFFC8C8CE), // brighter than the fill
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
