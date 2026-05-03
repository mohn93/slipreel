import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_graph_painter.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Inline graph editor used by the Animation tab and the per-region
/// override section. Live: every drag / chip / numeric edit calls back
/// immediately so the canvas reflects the curve in real time.
class CurveEditor extends StatefulWidget {
  const CurveEditor({
    super.key,
    required this.curve,
    required this.duration,
    required this.durationLabel,
    required this.durationMin,
    required this.durationMax,
    required this.onCurveChanged,
    required this.onDurationChanged,
    required this.library,
    required this.showDurationSlider,
  });

  final CubicBezierCurve curve;
  final Duration duration;
  final String durationLabel;
  final Duration durationMin;
  final Duration durationMax;
  final ValueChanged<CubicBezierCurve> onCurveChanged;
  final ValueChanged<Duration> onDurationChanged;
  final CurveLibrary library;
  final bool showDurationSlider;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _demoCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  int _draggingHandle = 0;
  List<NamedCurve> _saved = const [];
  bool _showSaveField = false;
  final TextEditingController _saveName = TextEditingController();

  late TextEditingController _x1, _y1, _x2, _y2;

  late final FocusNode _x1Focus = FocusNode();
  late final FocusNode _y1Focus = FocusNode();
  late final FocusNode _x2Focus = FocusNode();
  late final FocusNode _y2Focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _x1 = TextEditingController(text: widget.curve.x1.toStringAsFixed(2));
    _y1 = TextEditingController(text: widget.curve.y1.toStringAsFixed(2));
    _x2 = TextEditingController(text: widget.curve.x2.toStringAsFixed(2));
    _y2 = TextEditingController(text: widget.curve.y2.toStringAsFixed(2));
    _refreshLibrary();
  }

  @override
  void didUpdateWidget(covariant CurveEditor old) {
    super.didUpdateWidget(old);
    if (old.curve != widget.curve) {
      // Don't stomp text in a focused field — the user is mid-edit and
      // our text-update would jump their cursor. Their typed value
      // flows back via _commitNumeric on submit/blur.
      if (!_x1Focus.hasFocus) {
        _x1.text = widget.curve.x1.toStringAsFixed(2);
      }
      if (!_y1Focus.hasFocus) {
        _y1.text = widget.curve.y1.toStringAsFixed(2);
      }
      if (!_x2Focus.hasFocus) {
        _x2.text = widget.curve.x2.toStringAsFixed(2);
      }
      if (!_y2Focus.hasFocus) {
        _y2.text = widget.curve.y2.toStringAsFixed(2);
      }
    }
  }

  @override
  void dispose() {
    _demoCtrl.dispose();
    _saveName.dispose();
    _x1.dispose();
    _y1.dispose();
    _x2.dispose();
    _y2.dispose();
    _x1Focus.dispose();
    _y1Focus.dispose();
    _x2Focus.dispose();
    _y2Focus.dispose();
    super.dispose();
  }

  Future<void> _refreshLibrary() async {
    final l = await widget.library.list();
    if (!mounted) return;
    setState(() => _saved = l);
  }

  void _commitNumeric(int idx, String raw) {
    final v = double.tryParse(raw);
    if (v == null) return;
    var x1 = widget.curve.x1;
    var y1 = widget.curve.y1;
    var x2 = widget.curve.x2;
    var y2 = widget.curve.y2;
    switch (idx) {
      case 0:
        x1 = v.clamp(0.0, 1.0);
        break;
      case 1:
        y1 = v.clamp(-0.5, 1.5);
        break;
      case 2:
        x2 = v.clamp(0.0, 1.0);
        break;
      case 3:
        y2 = v.clamp(-0.5, 1.5);
        break;
    }
    widget.onCurveChanged(CubicBezierCurve(x1: x1, y1: y1, x2: x2, y2: y2));
  }

  void _onDragHandle(int idx, Offset local, Size size) {
    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (1 - (local.dy / size.height)).clamp(-0.5, 1.5);
    var x1 = widget.curve.x1;
    var y1 = widget.curve.y1;
    var x2 = widget.curve.x2;
    var y2 = widget.curve.y2;
    if (idx == 1) {
      x1 = nx;
      y1 = ny;
    }
    if (idx == 2) {
      x2 = nx;
      y2 = ny;
    }
    widget.onCurveChanged(CubicBezierCurve(x1: x1, y1: y1, x2: x2, y2: y2));
  }

  int _hitTestHandle(Offset local, Size size) {
    Offset toScreen(double x, double y) =>
        Offset(x * size.width, (1 - y) * size.height);
    final h1 = toScreen(widget.curve.x1, widget.curve.y1);
    final h2 = toScreen(widget.curve.x2, widget.curve.y2);
    if ((local - h1).distance < 16) return 1;
    if ((local - h2).distance < 16) return 2;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        // Square graph, but capped so the editor stays usable when the
        // parent is much wider than tall (e.g. the inspector at desktop
        // widths or the 800x600 widget-test viewport).
        Center(
          child: LayoutBuilder(builder: (context, c) {
            final side = c.maxWidth.clamp(0.0, 280.0).toDouble();
            final size = Size(side, side);
            return SizedBox(
              width: side,
              height: side,
              child: GestureDetector(
                // Hit-test only at press time, not during pan: a press that
                // starts outside any handle is a no-op for the entire gesture.
                // This matches the typical "grab and drag" mental model and
                // avoids accidentally hijacking taps that started on the
                // background but happened to cross a handle mid-drag.
                onPanDown: (d) {
                  final h = _hitTestHandle(d.localPosition, size);
                  if (h != 0) setState(() => _draggingHandle = h);
                },
                onPanUpdate: (d) {
                  if (_draggingHandle != 0) {
                    _onDragHandle(_draggingHandle, d.localPosition, size);
                  }
                },
                onPanEnd: (_) => setState(() => _draggingHandle = 0),
                child: AnimatedBuilder(
                  animation: _demoCtrl,
                  builder: (_, __) => CustomPaint(
                    painter: CurveGraphPainter(
                      curve: widget.curve,
                      demoProgress: _demoCtrl.value,
                      draggingHandle: _draggingHandle,
                    ),
                    size: size,
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _numField(0, 'x1', _x1, _x1Focus)),
          const SizedBox(width: 6),
          Expanded(child: _numField(1, 'y1', _y1, _y1Focus)),
          const SizedBox(width: 6),
          Expanded(child: _numField(2, 'x2', _x2, _x2Focus)),
          const SizedBox(width: 6),
          Expanded(child: _numField(3, 'y2', _y2, _y2Focus)),
        ]),
        if (widget.showDurationSlider) ...[
          const SizedBox(height: 12),
          _DurationSlider(
            key: const ValueKey('curveEditor.durationSlider'),
            label: widget.durationLabel,
            value: widget.duration,
            min: widget.durationMin,
            max: widget.durationMax,
            onChanged: widget.onDurationChanged,
          ),
        ],
        const SizedBox(height: 12),
        const Text('Library',
            style: TextStyle(color: Colors.white, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final b in BuiltInCurves.all)
            _Chip(
              key: ValueKey('curveEditor.chip.builtin.${b.id}'),
              label: b.name,
              onTap: () => widget.onCurveChanged(b.curve),
            ),
          for (final s in _saved)
            _Chip(
              key: ValueKey('curveEditor.chip.saved.${s.id}'),
              label: s.name,
              onTap: () => widget.onCurveChanged(s.curve),
              onLongPress: () async {
                await widget.library.delete(s.id);
                _refreshLibrary();
              },
            ),
        ]),
        const SizedBox(height: 10),
        if (!_showSaveField)
          OutlinedButton(
            key: const ValueKey('curveEditor.saveButton'),
            onPressed: () => setState(() => _showSaveField = true),
            child: const Text('Save to library…'),
          )
        else
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('curveEditor.saveNameField'),
                controller: _saveName,
                decoration: const InputDecoration(hintText: 'Curve name'),
              ),
            ),
            const SizedBox(width: 6),
            ElevatedButton(
              key: const ValueKey('curveEditor.saveConfirm'),
              onPressed: () async {
                final name = _saveName.text.trim();
                if (name.isEmpty) return;
                await widget.library.save(name: name, curve: widget.curve);
                _saveName.clear();
                if (!mounted) return;
                setState(() => _showSaveField = false);
                _refreshLibrary();
              },
              child: const Text('Save'),
            ),
          ]),
      ],
    );
  }

  Widget _numField(
      int idx, String label, TextEditingController c, FocusNode focus) {
    final keyPrefix = ['x1', 'y1', 'x2', 'y2'][idx];
    return TextField(
      key: ValueKey('curveEditor.${keyPrefix}Field'),
      controller: c,
      focusNode: focus,
      keyboardType: const TextInputType.numberWithOptions(
          signed: true, decimal: true),
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      ),
      onSubmitted: (raw) => _commitNumeric(idx, raw),
      onEditingComplete: () => _commitNumeric(idx, c.text),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kInspectorBorder),
        ),
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
      ),
    );
  }
}

class _DurationSlider extends StatelessWidget {
  const _DurationSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final String label;
  final Duration value, min, max;
  final ValueChanged<Duration> onChanged;
  @override
  Widget build(BuildContext context) {
    final span = (max.inMicroseconds - min.inMicroseconds).clamp(1, 1 << 31);
    final t = (value.inMicroseconds - min.inMicroseconds) / span;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      Slider(
        value: t.clamp(0.0, 1.0).toDouble(),
        onChanged: (v) {
          final micros = min.inMicroseconds +
              ((max.inMicroseconds - min.inMicroseconds) * v).round();
          onChanged(Duration(microseconds: micros));
        },
      ),
      Text('${value.inMilliseconds} ms',
          style: const TextStyle(color: kInspectorMuted, fontSize: 11)),
    ]);
  }
}
