import 'dart:io';

import 'package:flutter/material.dart';

import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/motion_blur_playground_screen.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';

/// Lists previously recorded videos so the user can re-open or remove
/// them. Each row checks whether its file still exists; missing rows are
/// greyed and only offer "Remove from history".
class RecentsScreen extends StatefulWidget {
  const RecentsScreen({super.key, RecordingHistoryStore? store})
      : _injectedStore = store;

  final RecordingHistoryStore? _injectedStore;

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<RecentsScreen> {
  late final RecordingHistoryStore _store;
  List<RecordingHistoryEntry>? _entries;
  // Cache of which paths exist on disk. Recomputed when the screen
  // mounts and again after every history mutation.
  final Map<String, bool> _exists = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _store = widget._injectedStore ?? RecordingHistoryStore();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final list = await _store.load();
    final exists = <String, bool>{};
    for (final e in list) {
      exists[e.videoPath] = await File(e.videoPath).exists();
    }
    if (!mounted) return;
    setState(() {
      _entries = list;
      _exists
        ..clear()
        ..addAll(exists);
      _loading = false;
    });
  }

  Future<void> _remove(RecordingHistoryEntry e) async {
    final next = await _store.removeByPath(e.videoPath);
    if (!mounted) return;
    setState(() {
      _entries = next;
      _exists.remove(e.videoPath);
    });
  }

  void _open(RecordingHistoryEntry e) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaybackScreen(videoPath: e.videoPath),
    ));
  }

  void _openPlayground(RecordingHistoryEntry e) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          MotionBlurPlaygroundScreen(videoPath: e.videoPath),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text('Recent recordings',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF2B2B3D),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _entries == null) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF6C63FF)));
    }
    final entries = _entries ?? const [];
    if (entries.isEmpty) {
      return const _EmptyState();
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: entries.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Color(0xFF2B2B3D)),
      itemBuilder: (_, i) {
        final e = entries[i];
        final exists = _exists[e.videoPath] ?? false;
        return _RecentTile(
          entry: e,
          fileExists: exists,
          onOpen: exists ? () => _open(e) : null,
          onLongPress: exists ? () => _openPlayground(e) : null,
          onRemove: () => _remove(e),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.history, size: 56, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'No recordings yet',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w500),
            ),
            SizedBox(height: 8),
            Text(
              'Recordings you finish will show up here so you can re-open them later.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.entry,
    required this.fileExists,
    required this.onOpen,
    required this.onLongPress,
    required this.onRemove,
  });

  final RecordingHistoryEntry entry;
  final bool fileExists;
  final VoidCallback? onOpen;
  final VoidCallback? onLongPress;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final filename = entry.videoPath.split(Platform.pathSeparator).last;
    final dimensions =
        '${entry.widthPx}×${entry.heightPx} @ ${entry.fps}fps';
    final color = fileExists ? Colors.white : Colors.white38;
    final subtitleColor = fileExists ? Colors.white60 : Colors.white24;

    return InkWell(
      onTap: onOpen,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(
              fileExists
                  ? Icons.play_circle_outline
                  : Icons.broken_image_outlined,
              color: fileExists
                  ? const Color(0xFF6C63FF)
                  : Colors.white24,
              size: 30,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    filename,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      decoration: fileExists
                          ? TextDecoration.none
                          : TextDecoration.lineThrough,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    fileExists
                        ? '${_formatDate(entry.recordedAt)} · $dimensions'
                        : 'File not found · ${_formatDate(entry.recordedAt)}',
                    style: TextStyle(color: subtitleColor, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (fileExists && onLongPress != null)
              IconButton(
                tooltip: 'Open in motion-blur playground',
                icon: const Icon(Icons.tune, size: 18),
                color: Colors.white54,
                onPressed: onLongPress,
              ),
            if (!fileExists)
              TextButton(
                onPressed: onRemove,
                child: const Text(
                  'Remove',
                  style: TextStyle(color: Color(0xFFE5484D)),
                ),
              )
            else
              IconButton(
                tooltip: 'Remove from history',
                icon: const Icon(Icons.close, size: 18),
                color: Colors.white38,
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime when) {
    final local = when.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final date =
        '${local.year}-${two(local.month)}-${two(local.day)}';
    final time = '${two(local.hour)}:${two(local.minute)}';
    return '$date  $time';
  }
}
