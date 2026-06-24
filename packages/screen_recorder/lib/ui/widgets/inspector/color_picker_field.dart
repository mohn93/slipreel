// packages/screen_recorder/lib/ui/widgets/inspector/color_picker_field.dart
import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Curated preset solids for the picker (neutrals + saturated tones).
const List<Color> kSolidPresetColors = [
  Color(0xFF1A1A26), Color(0xFF2E2E3A), Color(0xFF5B6470), Color(0xFF9AA3B2),
  Color(0xFFE7E9EE), Color(0xFFFFFFFF), Color(0xFF6C63FF), Color(0xFF4FC3F7),
  Color(0xFF34C759), Color(0xFFFFD60A), Color(0xFFFF9F0A), Color(0xFFFF375F),
];

/// Parse `#RRGGBB` / `RRGGBB` to an opaque [Color], or null if invalid.
Color? parseHexColor(String input) {
  var s = input.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Format an opaque [Color] as an uppercase `#RRGGBB` string.
String formatHexColor(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// Reusable HSV color picker: saturation/brightness square + hue slider +
/// hex field + curated preset swatches. Emits [onChanged] continuously
/// during drag.
class ColorPickerField extends StatefulWidget {
  const ColorPickerField({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<ColorPickerField> createState() => _ColorPickerFieldState();
}

class _ColorPickerFieldState extends State<ColorPickerField> {
  late HSVColor _hsv;
  late TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.color);
    _hex = TextEditingController(text: formatHexColor(widget.color));
  }

  @override
  void didUpdateWidget(ColorPickerField old) {
    super.didUpdateWidget(old);
    if (widget.color.toARGB32() != _hsv.toColor().toARGB32()) {
      setState(() => _hsv = HSVColor.fromColor(widget.color));
      _hex.text = formatHexColor(widget.color);
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _emit(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final c = hsv.toColor();
    _hex.text = formatHexColor(c);
    widget.onChanged(c);
  }

  void _applyHex(String text) {
    final c = parseHexColor(text);
    if (c != null) _emit(HSVColor.fromColor(c));
  }

  Widget _thumb() => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 2)],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pure = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    final current = _hsv.toColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1.7,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final h = c.maxHeight;
              void handle(Offset p) => _emit(HSVColor.fromAHSV(
                    1,
                    _hsv.hue,
                    (p.dx / w).clamp(0.0, 1.0),
                    (1 - p.dy / h).clamp(0.0, 1.0),
                  ));
              return GestureDetector(
                key: const Key('sv-square'),
                onPanDown: (d) => handle(d.localPosition),
                onPanUpdate: (d) => handle(d.localPosition),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.white, pure],
                          ),
                        ),
                      ),
                    ),
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _hsv.saturation * w - 7,
                      top: (1 - _hsv.value) * h - 7,
                      child: _thumb(),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 14,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              void handle(Offset p) => _emit(HSVColor.fromAHSV(
                    1,
                    (p.dx / w).clamp(0.0, 1.0) * 360,
                    _hsv.saturation,
                    _hsv.value,
                  ));
              return GestureDetector(
                key: const Key('hue-slider'),
                onPanDown: (d) => handle(d.localPosition),
                onPanUpdate: (d) => handle(d.localPosition),
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        gradient: const LinearGradient(colors: [
                          Color(0xFFFF0000), Color(0xFFFFFF00),
                          Color(0xFF00FF00), Color(0xFF00FFFF),
                          Color(0xFF0000FF), Color(0xFFFF00FF),
                          Color(0xFFFF0000),
                        ]),
                      ),
                    ),
                  ),
                  Positioned(
                    left: ((_hsv.hue / 360) * w - 7).clamp(0.0, w - 14),
                    top: 0,
                    child: _thumb(),
                  ),
                ]),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: current,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kInspectorBorder),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _hex,
              onSubmitted: _applyHex,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                filled: true,
                fillColor: kInspectorPanel,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kInspectorBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kInspectorAccent),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in kSolidPresetColors)
            GestureDetector(
              key: ValueKey('preset-${c.toARGB32()}'),
              onTap: () => _emit(HSVColor.fromColor(c)),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: current.toARGB32() == c.toARGB32()
                        ? kInspectorAccent
                        : kInspectorBorder,
                    width: current.toARGB32() == c.toARGB32() ? 2 : 1,
                  ),
                ),
              ),
            ),
        ]),
      ],
    );
  }
}
