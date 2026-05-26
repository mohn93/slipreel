import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A thin horizontal mic level meter. The fill springs toward the latest 0..1
/// value from [levelStream]; a peak-hold marker jumps to the max and decays
/// slowly back (like an audio peak meter). Fills the width given by its parent.
class MicLevelMeter extends StatefulWidget {
  const MicLevelMeter({super.key, required this.levelStream, this.height = 3});

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
  double _peakAge = 0; // seconds since the peak was last bumped up

  // Spring (2nd-order): very high stiffness so the fill snaps to the level and
  // falls fast (settling ~0.2s), leaving the peak-hold marker to glide back on
  // its own. Damping slightly under critical keeps it lively without mush.
  static const double _stiffness = 1500;
  static const double _damping = 38;
  // Peak marker: pin at the top for this long, then fall slowly — so the
  // segment visibly hangs above the fast fill and creeps back down (VU-style
  // peak hold). Long hold + slow fall make the detachment easy to see.
  static const double _peakHoldSec = 0.3;
  static const double _peakDecayPerSec = 0.6;

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

    // Peak hold: snap up to the display and reset the hold timer; otherwise
    // keep it pinned for _peakHoldSec, then decay slowly (never below display).
    if (_display >= _peak) {
      _peak = _display;
      _peakAge = 0;
    } else {
      _peakAge += dt;
      if (_peakAge > _peakHoldSec) {
        _peak = math.max(_display, _peak - _peakDecayPerSec * dt);
      }
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
    return const Color(0xFFB4B4BC); // bright, prominent live bar
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
            // Peak band (dimmer grey): fills 0..peak behind the bright live
            // fill, so the stretch between the fill and the peak shows as a
            // dimmer-grey tail — it holds the recent max, then decays back.
            // Positioned so it never feeds an ancestor's intrinsic-width pass
            // (avoids a 0/0 NaN under IntrinsicWidth).
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: _peak.clamp(0.0, 1.0),
                  // Container (not ColoredBox) so it fills the loose height like
                  // the fill does — a ColoredBox would collapse to height 0.
                  child: Container(
                    key: const Key('mic-meter-peak'),
                    decoration: const BoxDecoration(color: Color(0xFF565660)),
                  ),
                ),
              ),
            ),
            // Fill (spring-animated): the bright live-level bar, painted over
            // the peak band so 0..display reads bright, display..peak dim.
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
          ],
        ),
      ),
    );
  }
}
