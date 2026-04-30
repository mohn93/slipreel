import 'package:flutter/material.dart';

import 'package:screen_recorder/models/zoom_region.dart';

/// Editor for the currently-selected zoom: enter ramp, hold zoom level,
/// exit ramp. Mutates the zoom via [onChanged] (the parent owns state).
class ZoomInspector extends StatelessWidget {
  const ZoomInspector({
    super.key,
    required this.zoom,
    required this.onChanged,
  });

  final ZoomRegion zoom;
  final ValueChanged<ZoomRegion> onChanged;

  static const _accent = Color(0xFF7C6BFF);
  static const _bg = Color(0xFF222232);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accent.withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Zoom inspector',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 6),
          _row(
            label: 'Enter',
            valueLabel: '${zoom.enterDuration.inMilliseconds} ms',
            value: zoom.enterDuration.inMilliseconds.toDouble(),
            min: 0,
            max: 2000,
            onChanged: (v) => onChanged(zoom.copyWith(
              enterDuration: Duration(milliseconds: v.round()),
            )),
          ),
          _row(
            label: 'Zoom',
            valueLabel: '${zoom.zoomLevel.toStringAsFixed(1)}×',
            value: zoom.zoomLevel,
            min: 1.0,
            max: 5.0,
            divisions: 40,
            onChanged: (v) => onChanged(zoom.copyWith(
              zoomLevel: (v * 10).round() / 10.0,
            )),
          ),
          _row(
            label: 'Exit',
            valueLabel: '${zoom.exitDuration.inMilliseconds} ms',
            value: zoom.exitDuration.inMilliseconds.toDouble(),
            min: 0,
            max: 2000,
            onChanged: (v) => onChanged(zoom.copyWith(
              exitDuration: Duration(milliseconds: v.round()),
            )),
          ),
        ],
      ),
    );
  }

  Widget _row({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: _accent,
              inactiveTrackColor: Colors.white12,
              thumbColor: _accent,
              overlayColor: _accent.withValues(alpha: 0.15),
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            valueLabel,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
