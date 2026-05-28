import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/motion_blur_playground_screen.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';
import 'package:screen_recorder/ui/screens/recents/recording_card.dart';
import 'package:screen_recorder/ui/screens/recents/recording_thumbnail_service.dart';

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

  final RecordingThumbnailService _thumbs = RecordingThumbnailService();
  // Per-entry Future memos so the same Future object is reused across rebuilds,
  // preventing FutureBuilder from restarting on every setState.
  final Map<String, Future<RecordingThumbnail>> _futures = {};

  @override
  void initState() {
    super.initState();
    _store = widget._injectedStore ?? RecordingHistoryStore();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final list = await _store.load();
    // Check all files in parallel, preserving the original list order.
    final existsResults =
        await Future.wait(list.map((e) => File(e.videoPath).exists()));
    final exists = <String, bool>{
      for (var i = 0; i < list.length; i++) list[i].videoPath: existsResults[i],
    };
    if (!mounted) return;
    setState(() {
      _entries = list;
      _exists
        ..clear()
        ..addAll(exists);
      // Clear the per-entry Future memo AND the service's in-memory memo
      // atomically with the entries swap. Clearing the service memo forces
      // thumbFor to re-run its disk-staleness check, so an edit (which bumps
      // editor.json) regenerates the thumbnail instead of serving a stale one.
      _futures.clear();
      _thumbs.clearMemoryCache();
      _loading = false;
    });
  }

  Future<void> _remove(RecordingHistoryEntry e) async {
    final next = await _store.removeByPath(e.videoPath);
    if (!mounted) return;
    setState(() {
      _entries = next;
      _exists.remove(e.videoPath);
      _futures.remove(e.videoPath);
    });
  }

  void _open(RecordingHistoryEntry e) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaybackScreen(videoPath: e.videoPath),
    ));
  }

  void _openPlayground(RecordingHistoryEntry e) {
    // Dev-only screen: unreachable in release builds so the playground
    // doesn't appear in the production binary's navigation graph.
    if (!kDebugMode) return;
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
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        childAspectRatio: 16 / 13,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final entry = entries[i];
        final exists = _exists[entry.videoPath] ?? false;
        return RecordingCard(
          entry: entry,
          fileExists: exists,
          thumbnailFuture: exists
              ? _futures.putIfAbsent(
                  entry.videoPath, () => _thumbs.thumbFor(entry))
              : null,
          onOpen: () => _open(entry),
          onOpenPlayground: () => _openPlayground(entry),
          onRemove: () => _remove(entry),
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

