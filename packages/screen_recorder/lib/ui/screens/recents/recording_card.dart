import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'recording_thumbnail_service.dart';

class RecordingCard extends StatefulWidget {
  const RecordingCard({
    super.key,
    required this.entry,
    required this.fileExists,
    required this.thumbnailFuture,
    required this.onOpen,
    required this.onOpenPlayground,
    required this.onRemove,
  });

  final RecordingHistoryEntry entry;
  final bool fileExists;

  /// The styled-thumbnail future, or null when no thumbnail should be loaded
  /// (e.g. the underlying file is missing). When null the card never
  /// subscribes to a future, so there is nothing that can error.
  final Future<RecordingThumbnail>? thumbnailFuture;
  final VoidCallback onOpen;
  final VoidCallback onOpenPlayground;
  final VoidCallback onRemove;

  @override
  State<RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends State<RecordingCard> {
  bool _hover = false;

  bool get _hasFuture => widget.fileExists && widget.thumbnailFuture != null;

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
          _subtitle(enabled),
        ],
      ),
    );
  }

  Widget _thumbArea() {
    if (!_hasFuture) return const _Placeholder();
    return FutureBuilder<RecordingThumbnail>(
      future: widget.thumbnailFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _LoadingPlaceholder();
        }
        if (snap.hasError || !snap.hasData) return const _Placeholder();
        return Image.file(
          snap.data!.pngFile,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const _Placeholder(),
        );
      },
    );
  }

  Widget _subtitle(bool enabled) {
    final dims = '${widget.entry.widthPx}×${widget.entry.heightPx}';
    final color = enabled ? Colors.white60 : Colors.white24;
    if (!_hasFuture) {
      return _SubtitleText(text: dims, color: color);
    }
    return FutureBuilder<RecordingThumbnail>(
      future: widget.thumbnailFuture,
      builder: (context, snap) {
        final dur = snap.hasData ? snap.data!.duration : null;
        final text = dur != null ? '${_fmtDuration(dur)} · $dims' : dims;
        return _SubtitleText(text: text, color: color);
      },
    );
  }
}

class _SubtitleText extends StatelessWidget {
  const _SubtitleText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 12),
      );
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

class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder();

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
