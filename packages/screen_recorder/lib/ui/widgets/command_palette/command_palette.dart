import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// One executable command — what shows up as a row in the palette.
/// [icon] is rendered to the LEFT of the label at 18 px; [action] is
/// invoked AFTER the palette dismisses, so it can safely show its
/// own dialogs / snackbars.
class CommandPaletteEntry {
  const CommandPaletteEntry({
    required this.label,
    required this.icon,
    required this.action,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback action;

  /// When false the row dims and the tap / Enter / arrow-Enter is
  /// suppressed. Use it for "Restore default zoom ranges" when there
  /// are no detectable zooms, etc.
  final bool enabled;
}

/// A labeled section of commands (Zoom / Export / Editor / etc.).
/// Sections that have no matching entries after filtering are hidden
/// entirely from the palette.
class CommandPaletteGroup {
  const CommandPaletteGroup({
    required this.title,
    required this.entries,
  });

  final String title;
  final List<CommandPaletteEntry> entries;
}

/// Searchable command picker modeled after macOS / VS Code palettes:
///   - Top: text field, autofocused so the user can just start
///     typing the moment it opens.
///   - Body: grouped, sectioned command list. The first matching
///     command is highlighted; ↑/↓ move the highlight; Enter
///     dispatches; Esc dismisses.
///   - Hover also drives the highlight, so click and keyboard
///     selection stay in sync.
///
/// Open with [showCommandPalette].
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.groups});

  final List<CommandPaletteGroup> groups;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

/// Renders the palette in a [showGeneralDialog] centered overlay
/// with a translucent scrim. Returns when the user picks (or
/// dismisses) — the chosen command's action has already run.
Future<void> showCommandPalette(
  BuildContext context, {
  required List<CommandPaletteGroup> groups,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    barrierLabel: 'Dismiss command palette',
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (ctx, _, __) {
      return CommandPalette(groups: groups);
    },
    transitionBuilder: (ctx, anim, _, child) {
      final fade = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      // Subtle scale + fade so the palette feels like it lands from
      // slightly above. Matches the recording bar / app-alerts
      // transition feel.
      return FadeTransition(
        opacity: fade,
        child: Transform.scale(
          scale: 0.96 + 0.04 * fade.value,
          alignment: Alignment.topCenter,
          child: child,
        ),
      );
    },
  );
}

class _CommandPaletteState extends State<CommandPalette> {
  late final TextEditingController _searchCtl;
  late final FocusNode _searchFocus;
  String _query = '';
  int _selectedCommandIndex = 0;
  final ScrollController _scrollCtl = ScrollController();

  @override
  void initState() {
    super.initState();
    _searchCtl = TextEditingController();
    _searchFocus = FocusNode();
    // Push autofocus to the next frame — autofocus during the
    // showGeneralDialog transition can race with the route's own
    // focus traversal and miss.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _searchFocus.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  /// Flattens groups → [_FlatRow]s, dropping groups whose entries
  /// all failed the substring filter. Headers only appear when their
  /// section still has visible commands; this keeps "no results"
  /// from collapsing into a wall of category titles.
  List<_FlatRow> _visibleRows() {
    final q = _query.trim().toLowerCase();
    final rows = <_FlatRow>[];
    for (final group in widget.groups) {
      final matches = group.entries
          .where((e) => q.isEmpty || e.label.toLowerCase().contains(q))
          .toList();
      if (matches.isEmpty) continue;
      rows.add(_FlatRow.header(group.title));
      rows.addAll(matches.map(_FlatRow.entry));
    }
    return rows;
  }

  /// Maps the [_selectedCommandIndex] to a row index in the visible
  /// list. Returns -1 if there are no commands to select.
  int _commandRowIndex(List<_FlatRow> rows, int cmdIndex) {
    var seen = 0;
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].isEntry) continue;
      if (seen == cmdIndex) return i;
      seen++;
    }
    return -1;
  }

  int _commandCount(List<_FlatRow> rows) =>
      rows.fold<int>(0, (acc, r) => acc + (r.isEntry ? 1 : 0));

  void _onQueryChanged(String q) {
    setState(() {
      _query = q;
      _selectedCommandIndex = 0;
    });
  }

  void _moveSelection(int delta) {
    final rows = _visibleRows();
    final total = _commandCount(rows);
    if (total == 0) return;
    setState(() {
      _selectedCommandIndex =
          (_selectedCommandIndex + delta).clamp(0, total - 1);
    });
  }

  void _activateSelected() {
    final rows = _visibleRows();
    final rowIdx = _commandRowIndex(rows, _selectedCommandIndex);
    if (rowIdx < 0) return;
    final entry = rows[rowIdx].entry!;
    if (!entry.enabled) return;
    _runEntry(entry);
  }

  void _runEntry(CommandPaletteEntry entry) {
    // Pop the palette FIRST so any dialog the action opens isn't
    // stacked behind it.
    Navigator.of(context).pop();
    // Defer until the pop has settled — Riverpod / state mutations
    // inside the action wouldn't see the unmounted dialog otherwise.
    WidgetsBinding.instance.addPostFrameCallback((_) => entry.action());
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final rows = _visibleRows();
    final selectedRowIdx = _commandRowIndex(rows, _selectedCommandIndex);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: CallbackShortcuts(
            // Bound on the wrapping widget so the TextField's own
            // key handling runs LAST — printable characters still go
            // to the field; arrow / enter / escape are intercepted
            // here before reaching it.
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.arrowDown):
                  () => _moveSelection(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp):
                  () => _moveSelection(-1),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).pop(),
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: palette.surfaceCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.dividerStrong),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSearchField(palette),
                    Container(height: 1, color: palette.dividerSubtle),
                    Flexible(
                      child: rows.isEmpty
                          ? _buildEmpty(palette)
                          : SingleChildScrollView(
                              controller: _scrollCtl,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var i = 0; i < rows.length; i++)
                                    _buildRow(
                                      palette: palette,
                                      row: rows[i],
                                      isSelected: i == selectedRowIdx,
                                      commandIndex: rows[i].isEntry
                                          ? _commandIndexAt(rows, i)
                                          : -1,
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: TextField(
        controller: _searchCtl,
        focusNode: _searchFocus,
        onChanged: _onQueryChanged,
        onSubmitted: (_) => _activateSelected(),
        cursorColor: palette.accent,
        decoration: InputDecoration(
          hintText: 'Type to find a command',
          hintStyle: TextStyle(
            color: palette.textSecondary,
            fontSize: 15,
          ),
          border: InputBorder.none,
          isCollapsed: true,
        ),
        style: TextStyle(
          color: palette.textPrimary,
          fontSize: 15,
        ),
      ),
    );
  }

  /// Walk rows up to [rowIdx] counting commands so we can map a
  /// visible row back to its index in the keyboard-navigable command
  /// list. Used so hover / click can put the highlight on the right
  /// command without recomputing the whole flat list.
  int _commandIndexAt(List<_FlatRow> rows, int rowIdx) {
    var count = 0;
    for (var i = 0; i < rowIdx; i++) {
      if (rows[i].isEntry) count++;
    }
    return count;
  }

  Widget _buildRow({
    required AppPalette palette,
    required _FlatRow row,
    required bool isSelected,
    required int commandIndex,
  }) {
    if (row.isHeader) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(
          row.header!,
          style: TextStyle(
            color: palette.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    final entry = row.entry!;
    final enabled = entry.enabled;
    final fg = enabled
        ? palette.textPrimary
        : palette.textSecondary.withValues(alpha: 0.4);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled
            ? (_) {
                if (_selectedCommandIndex != commandIndex) {
                  setState(() => _selectedCommandIndex = commandIndex);
                }
              }
            : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => _runEntry(entry) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(entry.icon, size: 18, color: fg),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    entry.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.all(36),
      child: Text(
        'No commands match "${_query.trim()}"',
        textAlign: TextAlign.center,
        style: TextStyle(color: palette.textSecondary, fontSize: 14),
      ),
    );
  }
}

/// One row in the flattened command list — either a section header
/// or an actual command entry. Discriminated via [isHeader] /
/// [isEntry] so the build loop can dispatch without runtime type
/// checks.
class _FlatRow {
  const _FlatRow.header(String this.header)
      : entry = null,
        isHeader = true,
        isEntry = false;
  const _FlatRow.entry(CommandPaletteEntry this.entry)
      : header = null,
        isHeader = false,
        isEntry = true;

  final String? header;
  final CommandPaletteEntry? entry;
  final bool isHeader;
  final bool isEntry;
}
