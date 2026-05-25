import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'recording_thumbnail_service.dart';

class RecordingCard extends StatefulWidget {
  RecordingCard({
    super.key,
    required this.entry,
    required this.fileExists,
    required Future<RecordingThumbnail> thumbnailFuture,
    required this.onOpen,
    required this.onOpenPlayground,
    required this.onRemove,
  }) : thumbnailFuture = _makeSafe(thumbnailFuture);

  final RecordingHistoryEntry entry;
  final bool fileExists;
  // Internally the future is always the safe (error-converted) variant so
  // the zone never sees an "unhandled" error. Errors become null values.
  final Future<RecordingThumbnail?> thumbnailFuture;
  final VoidCallback onOpen;
  final VoidCallback onOpenPlayground;
  final VoidCallback onRemove;

  /// Converts any error into a null completion so that FutureBuilder renders
  /// a placeholder instead of propagating the exception to the zone.
  static Future<RecordingThumbnail?> _makeSafe(
      Future<RecordingThumbnail> f) {
    return f.then<RecordingThumbnail?>(
      (v) => v,
      onError: (Object _, StackTrace __) => null,
    );
  }

  @override
  State<RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends State<RecordingCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.fileExists;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Material(
                    color: const Color(0xFF2B2B3D),
                    child: InkWell(
                      onTap: enabled ? widget.onOpen : null,
                      onLongPress: enabled ? widget.onOpenPlayground : null,
                      child: _thumbArea(),
                    ),
                  ),
                ),
              ),
              if (_hover)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _RemoveButton(onRemove: widget.onRemove),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _formatDate(widget.entry.recordedAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: enabled ? Colors.white : Colors.white38,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          _SubtitleLine(
            entry: widget.entry,
            future: widget.thumbnailFuture,
            enabled: enabled,
          ),
        ],
      ),
    );
  }

  Widget _thumbArea() {
    if (!widget.fileExists) return const _Placeholder();
    return FutureBuilder<RecordingThumbnail?>(
      future: widget.thumbnailFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _Shimmer();
        }
        final thumb = snap.data;
        if (thumb == null) return const _Placeholder();
        return Image.file(
          thumb.pngFile,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const _Placeholder(),
        );
      },
    );
  }
}

class _SubtitleLine extends StatelessWidget {
  const _SubtitleLine({
    required this.entry,
    required this.future,
    required this.enabled,
  });

  final RecordingHistoryEntry entry;
  final Future<RecordingThumbnail?> future;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final dims = '${entry.widthPx}×${entry.heightPx}';
    final color = enabled ? Colors.white60 : Colors.white24;
    return FutureBuilder<RecordingThumbnail?>(
      future: future,
      builder: (context, snap) {
        final dur = snap.data?.duration;
        final text = dur != null ? '${_fmtDuration(dur)} · $dims' : dims;
        return Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 12),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) => const Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: Colors.white24,
          size: 32,
        ),
      );
}

class _Shimmer extends StatelessWidget {
  const _Shimmer();

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF23232F));
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onRemove});

  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(
          icon: const Icon(Icons.close, size: 16, color: Colors.white),
          tooltip: 'Remove from history',
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: onRemove,
        ),
      );
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime dt) {
  final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  final min = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day}, ${dt.year} · $h:$min $ampm';
}

String _fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
