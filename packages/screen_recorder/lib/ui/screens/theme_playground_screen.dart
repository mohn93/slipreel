import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/app_palette_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

class ThemePlaygroundScreen extends ConsumerWidget {
  const ThemePlaygroundScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appPaletteControllerProvider);
    final palette = context.palette;

    return Scaffold(
      backgroundColor: palette.appBackground,
      appBar: AppBar(
        title: const Text('Theme playground'),
        backgroundColor: palette.surfaceElevated,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: palette.dividerSubtle),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(context, 'Palette'),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final id in PaletteId.values) ...[
                  Expanded(
                    child: _SwatchTile(
                      id: id,
                      active: id == selected,
                      onTap: () => ref
                          .read(appPaletteControllerProvider.notifier)
                          .select(id),
                    ),
                  ),
                  if (id != PaletteId.values.last) const SizedBox(width: 12),
                ],
              ],
            ),
            const SizedBox(height: 32),
            _sectionTitle(context, 'Preview'),
            const SizedBox(height: 12),
            _MiniatureEditorPreview(palette: palette),
            const SizedBox(height: 32),
            _sectionTitle(context, 'Tokens'),
            const SizedBox(height: 12),
            _TokenGrid(palette: palette),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Text(
        text,
        style: TextStyle(
          color: context.palette.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _SwatchTile extends StatelessWidget {
  const _SwatchTile({
    required this.id,
    required this.active,
    required this.onTap,
  });

  final PaletteId id;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.byId(id);
    final activePalette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: p.appBackground,
          border: Border.all(
            color: active ? activePalette.accent : activePalette.dividerSubtle,
            width: active ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: p.surfaceElevated,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 28,
                    decoration: BoxDecoration(
                      color: p.surfaceCard,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(height: 1, color: p.dividerSubtle),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 30,
                        height: 16,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 16,
                          decoration: BoxDecoration(
                            color: p.surfaceLow,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    _labelFor(id),
                    style: TextStyle(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: activePalette.accent,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.check, size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _labelFor(PaletteId id) => switch (id) {
        PaletteId.midnight => 'Midnight',
        PaletteId.carbon => 'Carbon',
        PaletteId.obsidian => 'Obsidian',
      };
}

class _MiniatureEditorPreview extends StatelessWidget {
  const _MiniatureEditorPreview({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 320,
        decoration: BoxDecoration(
          color: palette.appBackground,
          border: Border.all(color: palette.dividerSubtle),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Container(
              height: 36,
              color: palette.surfaceElevated,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Text(
                'Editor',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(height: 1, color: palette.dividerSubtle),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 7,
                    child: Container(
                      color: palette.surfaceLow,
                      alignment: Alignment.center,
                      child: Container(
                        width: 80,
                        height: 50,
                        decoration: BoxDecoration(
                          color: palette.accent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                  Container(width: 1, color: palette.dividerSubtle),
                  Expanded(
                    flex: 3,
                    child: Container(
                      color: palette.surfaceElevated,
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Inspector',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: palette.surfaceCard,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Slider',
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: palette.dividerSubtle,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.accentMuted,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    'chip',
                                    style: TextStyle(
                                      color: palette.accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: palette.dividerSubtle),
            Container(
              height: 36,
              color: palette.surfaceElevated,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 18,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenGrid extends StatelessWidget {
  const _TokenGrid({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final tokens = <(String, Color)>[
      ('appBackground', palette.appBackground),
      ('surfaceLow', palette.surfaceLow),
      ('surfaceElevated', palette.surfaceElevated),
      ('surfaceCard', palette.surfaceCard),
      ('dividerSubtle', palette.dividerSubtle),
      ('dividerStrong', palette.dividerStrong),
      ('accent', palette.accent),
      ('accentMuted', palette.accentMuted),
      ('textPrimary', palette.textPrimary),
      ('textSecondary', palette.textSecondary),
    ];

    return GridView.count(
      crossAxisCount: 5,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final (name, color) in tokens)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.surfaceCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.dividerSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.dividerSubtle),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  name,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _hexOf(color),
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _hexOf(Color c) {
    // ignore: deprecated_member_use
    final v = c.value & 0xFFFFFFFF;
    return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
}
