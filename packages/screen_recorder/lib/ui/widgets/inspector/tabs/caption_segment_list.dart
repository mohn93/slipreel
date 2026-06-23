import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

import '../inspector_widgets.dart';

String _fmt(int micros) {
  final d = Duration(microseconds: micros);
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final ms = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
  return '$m:$s.$ms';
}

/// Editable list of caption segments. Edits flow straight to the
/// editor controller. [onSeek] (when provided) jumps the preview to a segment.
class CaptionSegmentList extends ConsumerWidget {
  const CaptionSegmentList({super.key, this.onSeek});

  final void Function(Duration position)? onSeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final segments = ref.watch(
      editorProjectControllerProvider.select((s) => s.captions),
    );
    final controller = ref.read(editorProjectControllerProvider.notifier);

    if (segments.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        for (var i = 0; i < segments.length; i++)
          _SegmentRow(
            key: ValueKey(segments[i].id),
            index: i,
            segment: segments[i],
            isLast: i == segments.length - 1,
            onSeek: onSeek,
            controller: controller,
          ),
      ],
    );
  }
}

class _SegmentRow extends StatefulWidget {
  const _SegmentRow({
    super.key,
    required this.index,
    required this.segment,
    required this.isLast,
    required this.controller,
    this.onSeek,
  });

  final int index;
  final CaptionSegment segment;
  final bool isLast;
  final EditorProjectController controller;
  final void Function(Duration)? onSeek;

  @override
  State<_SegmentRow> createState() => _SegmentRowState();
}

class _SegmentRowState extends State<_SegmentRow> {
  late final TextEditingController _text =
      TextEditingController(text: widget.segment.text);

  @override
  void didUpdateWidget(_SegmentRow old) {
    super.didUpdateWidget(old);
    // Keep the field in sync when the segment changes identity (split/merge).
    // The ValueKey(segment.id) on the row means a typing rebuild never reaches
    // here with the same id, so the id check alone is safe and won't clobber
    // the caret while the user is typing.
    if (old.segment.id != widget.segment.id) {
      _text.text = widget.segment.text;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seg = widget.segment;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => widget.onSeek?.call(seg.start),
                child: Text(
                  '${_fmt(seg.startMicros)} – ${_fmt(seg.endMicros)}',
                  style: const TextStyle(fontSize: 11, color: kInspectorMuted),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Split',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.call_split, size: 16),
                onPressed: () => widget.controller.splitCaptionAt(
                  widget.index,
                  (seg.startMicros + seg.endMicros) ~/ 2,
                ),
              ),
              if (!widget.isLast)
                IconButton(
                  tooltip: 'Merge with next',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.merge, size: 16),
                  onPressed: () =>
                      widget.controller.mergeCaptionWithNext(widget.index),
                ),
              IconButton(
                tooltip: 'Delete',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 16),
                onPressed: () =>
                    widget.controller.removeCaptionAt(widget.index),
              ),
            ],
          ),
          TextField(
            controller: _text,
            maxLines: null,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            onChanged: (v) =>
                widget.controller.updateCaptionTextAt(widget.index, v),
          ),
        ],
      ),
    );
  }
}
