import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../state/recording_state.dart';
import '../widgets/source_picker/accessibility_notice.dart';
import '../widgets/source_picker/concurrent_loader.dart';
import '../widgets/source_picker/permission_cta.dart';
import '../widgets/source_picker/region_tab_content.dart';
import '../widgets/source_picker/source_grid.dart';
import '../widgets/source_picker/thumbnail_cache.dart';
import 'playback_screen.dart';
import 'recents_screen.dart';

class RecordingScreen extends ConsumerStatefulWidget {
  const RecordingScreen({super.key});

  @override
  ConsumerState<RecordingScreen> createState() => _RecordingScreenState();
}

enum _Tab { windows, screens, region }

class _RecordingScreenState extends ConsumerState<RecordingScreen> {
  _Tab _tab = _Tab.windows;
  bool _strictFilter = true;
  bool _drawingRegion = false;
  bool _loading = true;
  bool _permissionDenied = false;
  String? _error;
  SourceList _sources = const SourceList();

  late final ThumbnailCache _cache = ThumbnailCache();
  late final ConcurrentLoader _loader = ConcurrentLoader(maxInFlight: 4);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _permissionDenied = false;
    });
    try {
      final result = await ScreenRecorderPlatform.instance
          .listSources(strictFilter: _strictFilter);
      if (!mounted) return;
      setState(() {
        _sources = result;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _permissionDenied =
            e.message?.toLowerCase().contains('permission') ?? false;
        _error = _permissionDenied ? null : (e.message ?? e.code);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    _cache.clear();
    await _load();
  }

  void _selectTab(_Tab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    ref.read(recordingControllerProvider.notifier)
        .selectSource(kind: null, id: null);
  }

  Future<void> _toggleStrictFilter(bool value) async {
    setState(() => _strictFilter = value);
    await _refresh();
  }

  Future<void> _drawRegion() async {
    setState(() => _drawingRegion = true);
    try {
      final region = await ScreenRecorderPlatform.instance.selectRegion();
      if (!mounted) return;
      if (region != null) {
        ref.read(recordingControllerProvider.notifier).selectSource(
              kind: RecordingSource.area,
              id: region.displayId,
              region: region,
            );
      }
    } finally {
      if (mounted) setState(() => _drawingRegion = false);
    }
  }

  Future<Uint8List?> _fetchThumbnail(String id, RecordingSource kind) =>
      ScreenRecorderPlatform.instance
          .captureThumbnail(id, kind, maxDimension: 480);

  @override
  Widget build(BuildContext context) {
    ref.listen<RecordingState>(recordingControllerProvider, (previous, next) {
      if (previous?.status != RecordingStatus.completed &&
          next.status == RecordingStatus.completed &&
          next.videoPath != null) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlaybackScreen(videoPath: next.videoPath!),
        ));
      }
    });

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text('Slipreel',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF2B2B3D),
        elevation: 0,
        actions: [
          if (_tab == _Tab.windows)
            IconButton(
              tooltip: 'Show all windows',
              icon: Icon(
                  _strictFilter ? Icons.visibility_off : Icons.visibility),
              onPressed: () => _toggleStrictFilter(!_strictFilter),
            ),
          IconButton(
            tooltip: 'Recent recordings',
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const RecentsScreen(),
              ));
            },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          // Show the Accessibility-permission notice above the source
          // list whenever screen-recording itself is granted (if both
          // are missing, the full-screen PermissionCta takes over and
          // this row collapses since the body is Expanded). The notice
          // self-hides once Accessibility is trusted.
          if (!_permissionDenied) const AccessibilityNotice(),
          _buildSegmentedControl(),
          Expanded(child: _buildBody()),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildSegmentedControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<_Tab>(
        segments: const [
          ButtonSegment(
              value: _Tab.windows,
              label: Text('Windows'),
              icon: Icon(Icons.window)),
          ButtonSegment(
              value: _Tab.screens,
              label: Text('Screens'),
              icon: Icon(Icons.desktop_windows)),
          ButtonSegment(
              value: _Tab.region,
              label: Text('Region'),
              icon: Icon(Icons.crop)),
        ],
        selected: {_tab},
        onSelectionChanged: (s) => _selectTab(s.first),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF6C63FF)));
    }
    if (_permissionDenied) return PermissionCta(onRetry: _refresh);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child:
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }
    if (_tab == _Tab.region) {
      final state = ref.watch(recordingControllerProvider);
      String? displayName;
      if (state.selectedRegion != null) {
        for (final s in _sources.screens) {
          if (s.id == state.selectedRegion!.displayId) {
            displayName = s.name;
            break;
          }
        }
      }
      return RegionTabContent(
        selection: state.selectedRegion,
        displayName: displayName,
        isDrawing: _drawingRegion,
        onDraw: _drawRegion,
      );
    }
    final items =
        _tab == _Tab.windows ? _windowItems() : _screenItems();
    if (items.isEmpty) return _buildEmptyState();
    final state = ref.watch(recordingControllerProvider);
    return SourceGrid(
      items: items,
      cache: _cache,
      loader: _loader,
      fetcher: _fetchThumbnail,
      selectedId: state.selectedSourceId,
      selectedKind: state.selectedSourceKind,
      onSelect: (item) => ref
          .read(recordingControllerProvider.notifier)
          .selectSource(kind: item.kind, id: item.id),
    );
  }

  List<SourceGridItem> _windowItems() => _sources.windows
      .map((w) => SourceGridItem(
            id: w.id,
            kind: RecordingSource.window,
            title: w.title,
            subtitle: w.ownerName,
            fallbackIcon: Icons.window,
          ))
      .toList();

  List<SourceGridItem> _screenItems() => _sources.screens
      .map((s) => SourceGridItem(
            id: s.id,
            kind: RecordingSource.screen,
            title: s.name,
            subtitle:
                '${s.width} × ${s.height}${s.isPrimary ? ' · Main' : ''}',
            fallbackIcon: Icons.desktop_windows,
          ))
      .toList();

  Widget _buildEmptyState() {
    if (_tab == _Tab.windows) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.window_outlined,
                  size: 48, color: Colors.white38),
              const SizedBox(height: 16),
              Text(
                _strictFilter
                    ? 'No app windows detected. Open a window you want to record, then tap refresh.'
                    : 'No windows available. Tap refresh.',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child:
          Text('No displays found.', style: TextStyle(color: Colors.white70)),
    );
  }

  Widget _buildBottomBar() {
    final state = ref.watch(recordingControllerProvider);
    final title = _selectedTitle(state);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF2B2B3D),
        boxShadow: [
          BoxShadow(
              color: Colors.black26, blurRadius: 8, offset: Offset(0, -2))
        ],
      ),
      child: Column(
        children: [
          if (title != null)
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500))
          else
            Text(
              _tab == _Tab.region
                  ? 'Draw a region first'
                  : 'Pick a window or screen above',
              style: const TextStyle(color: Colors.white38),
            ),
          const SizedBox(height: 12),
          _RecordButton(
              enabled: state.selectedSourceId != null &&
                  state.canStartRecording),
        ],
      ),
    );
  }

  String? _selectedTitle(RecordingState s) {
    final id = s.selectedSourceId;
    if (id == null) return null;
    if (s.selectedSourceKind == RecordingSource.window) {
      for (final w in _sources.windows) {
        if (w.id == id) return w.title;
      }
      return null;
    }
    if (s.selectedSourceKind == RecordingSource.screen) {
      for (final scr in _sources.screens) {
        if (scr.id == id) return scr.name;
      }
      return null;
    }
    if (s.selectedSourceKind == RecordingSource.area && s.selectedRegion != null) {
      final r = s.selectedRegion!;
      String? screenName;
      for (final scr in _sources.screens) {
        if (scr.id == r.displayId) { screenName = scr.name; break; }
      }
      return 'Region ${r.widthPx}×${r.heightPx} on ${screenName ?? 'Display ${r.displayId}'}';
    }
    return null;
  }
}

class _RecordButton extends ConsumerWidget {
  const _RecordButton({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final notifier = ref.read(recordingControllerProvider.notifier);
    if (state.isRecording) {
      return FilledButton.icon(
        onPressed: notifier.stopRecording,
        icon: const Icon(Icons.stop),
        label: const Text('Stop'),
      );
    }
    return FilledButton.icon(
      onPressed: enabled ? notifier.startRecording : null,
      icon: const Icon(Icons.fiber_manual_record),
      label: const Text('Record'),
    );
  }
}
