import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'concurrent_loader.dart';
import 'source_tile.dart';
import 'thumbnail_cache.dart';

typedef ThumbnailFetcher = Future<Uint8List?> Function(
  String id,
  RecordingSource kind,
);

class SourceGridItem {
  const SourceGridItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.fallbackIcon,
  });

  final String id;
  final RecordingSource kind;
  final String title;
  final String subtitle;
  final IconData fallbackIcon;
}

class SourceGrid extends StatefulWidget {
  const SourceGrid({
    super.key,
    required this.items,
    required this.cache,
    required this.loader,
    required this.fetcher,
    required this.selectedId,
    required this.onSelect,
  });

  final List<SourceGridItem> items;
  final ThumbnailCache cache;
  final ConcurrentLoader loader;
  final ThumbnailFetcher fetcher;
  final String? selectedId;
  final void Function(SourceGridItem item) onSelect;

  @override
  State<SourceGrid> createState() => _SourceGridState();
}

class _SourceGridState extends State<SourceGrid> {
  final Set<String> _erroredKeys = {};
  final Set<String> _inFlight = {};

  String _key(SourceGridItem i) => '${i.kind.name}:${i.id}';

  void _kickoff(SourceGridItem item) {
    final key = _key(item);
    if (_inFlight.contains(key)) return;
    if (widget.cache.get(item.kind, item.id) != null) return;
    if (_erroredKeys.contains(key)) return;
    _inFlight.add(key);
    widget.loader
        .run<Uint8List?>(() => widget.fetcher(item.id, item.kind))
        .then((bytes) {
      if (!mounted) return;
      setState(() {
        _inFlight.remove(key);
        if (bytes == null) {
          _erroredKeys.add(key);
        } else {
          widget.cache.put(item.kind, item.id, bytes);
        }
      });
    }).catchError((_) {
      if (!mounted) return null;
      setState(() {
        _inFlight.remove(key);
        _erroredKeys.add(key);
      });
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 800 ? 3 : 2;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 4 / 3,
          ),
          itemCount: widget.items.length,
          itemBuilder: (context, i) {
            final item = widget.items[i];
            final bytes = widget.cache.get(item.kind, item.id);
            final errored = _erroredKeys.contains(_key(item));
            if (bytes == null && !errored) _kickoff(item);
            return SourceTile(
              title: item.title,
              subtitle: item.subtitle,
              thumbnail: bytes,
              isSelected: widget.selectedId == item.id,
              isErrored: errored,
              fallbackIcon: item.fallbackIcon,
              onTap: () => widget.onSelect(item),
            );
          },
        );
      },
    );
  }
}
