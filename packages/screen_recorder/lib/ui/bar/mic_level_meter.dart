import 'dart:async';
import 'package:flutter/material.dart';

/// A thin horizontal level meter that fills left→right with the latest value
/// from [levelStream] (0..1). Fills the width given by its parent. The fill is
/// the bar's light accent, shifting to amber and then red near clip.
class MicLevelMeter extends StatefulWidget {
  const MicLevelMeter({super.key, required this.levelStream, this.height = 6});

  final Stream<double> levelStream;
  final double height;

  @override
  State<MicLevelMeter> createState() => _MicLevelMeterState();
}

class _MicLevelMeterState extends State<MicLevelMeter> {
  double _level = 0;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
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
      setState(() => _level = l.isFinite ? l.clamp(0.0, 1.0) : 0.0);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Color get _fillColor {
    if (_level >= 0.97) return const Color(0xFFE5484D); // red near clip
    if (_level >= 0.85) return const Color(0xFFF5A623); // amber
    return const Color(0xFFE9E9EC); // normal accent
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
              child: ColoredBox(color: Color(0x1FFFFFFF)), // track
            ),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: _level,
              child: Container(
                key: const Key('mic-meter-fill'),
                decoration: BoxDecoration(color: _fillColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
