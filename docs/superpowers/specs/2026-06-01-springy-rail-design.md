# Springy Inspector Rail — Design Spec

**Date:** 2026-06-01
**Status:** Approved, ready for implementation plan.

## Goal

Replace the inspector tab rail's existing `_RailButton`/`_AccentDot` with two new reusable widgets — a `SpringyIconButton` (spring-physics scale on hover/press, "stuck" enlarged state when active) and an `AnimatedIndicatorBar` (vertical accent bar to the left of the active button that spring-animates between selections). Move tooltips to the LEFT of each button. Delete the top-right accent dot badge.

## Non-Goals

- **No transport-button migration.** The transport bar's ⏮/▶/⏭ buttons stay as-is for now.
- **No canvas toolbar migration.** AspectRatioPicker stays; it's a dropdown, not an icon button.
- **No RecordingBar migration.** The 68px bar window has its own deliberately tuned chrome.
- **No InspectorChipGroup migration.** Different shape, different interaction.
- **No animation framework.** Use Flutter's built-in `SpringSimulation` + `AnimationController` + `TweenAnimationBuilder`. No `flutter_animate` dependency.
- **No golden-image tests.** Codebase convention.

## Architecture Summary

Two small, focused widgets under `packages/screen_recorder/lib/ui/widgets/`. The inspector rail composes them in a Stack: an `AnimatedIndicatorBar` painted first (left edge of the rail), and a Column of `SpringyIconButton`s painted on top. No state lives in the bar widget; it derives everything from `selectedIndex`. The button owns its own hover/press AnimationController.

```
inspector_panel.dart rail builder
        │
        ▼
Stack(
  AnimatedIndicatorBar(selectedIndex, itemCount, itemHeight, itemGap)
  Column([SpringyIconButton(icon, tooltip, isActive, onTap), …7])
)
```

## SpringyIconButton

### Public API

New file: `packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart`.

```dart
class SpringyIconButton extends StatefulWidget {
  const SpringyIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onTap,
    this.size = 40,
    this.iconSize = 20,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
}
```

### Visual states

| State | Scale | Background | Icon color |
|---|---|---|---|
| Inactive resting | 1.00 | transparent | `palette.textSecondary` |
| Inactive hover | 1.08 | `palette.accentMuted` × 0.4 (≈7% alpha accent) | `palette.textPrimary` |
| Inactive press-down | 0.94 | same as hover | `palette.textPrimary` |
| Active resting | 1.00 | `palette.accentMuted` | `palette.accent` |
| Active hover | 1.04 | `palette.accentMuted` × 1.1 (slightly stronger) | `palette.accent` |
| Active press-down | 0.94 | `palette.accentMuted` × 1.1 | `palette.accent` |

The "× 0.4" / "× 1.1" notations on the background tint refer to multiplying the alpha channel of `palette.accentMuted` (which is already 18% by definition). For example "× 0.4" → final alpha ≈ 7.2%. Implemented as `palette.accent.withValues(alpha: 0.18 * 0.4)`.

### Spring physics

Internal `AnimationController` drives a `SpringSimulation` for the scale value.

- **SpringDescription:** `mass: 1.0, stiffness: 220.0, damping: 16.0`. Yields ~10% overshoot before settling. Total settle time ~280–320ms depending on delta.
- **Trigger transitions** via `controller.animateWith(SpringSimulation(spring, currentScale, targetScale, currentVelocity))` so the spring picks up from wherever the prior animation was, preserving velocity.
- **Targets:** resting/hover/press scales come from the table above, branching on `widget.isActive`.

Background tint and icon color animate via `AnimatedContainer` / `TweenAnimationBuilder<Color>` with `Curves.easeOutCubic`, 200ms. Color tweens don't benefit from spring overshoot.

### Tooltip — `_LeftTooltip`

The widget wraps its child in a private `_LeftTooltip(message: tooltip)` (NOT Flutter's stock `Tooltip` — that defaults below).

`_LeftTooltip` is a `StatefulWidget` that:
1. Wraps its child in a `MouseRegion(onEnter: …, onExit: …)`.
2. On `onEnter`, schedules a 500 ms `Timer`. When it fires, inserts an `OverlayEntry` containing the tooltip chip.
3. On `onExit` (or pointer-down), cancels the pending timer and removes the entry.
4. Positions the overlay using a `CompositedTransformFollower` + `CompositedTransformTarget` pair anchored to the child:
   - `targetAnchor: Alignment.centerLeft`
   - `followerAnchor: Alignment.centerRight`
   - `offset: const Offset(-8, 0)` (8 px gap)

Chip styling:
- Padding: `EdgeInsets.symmetric(horizontal: 8, vertical: 5)`.
- Decoration: `BoxDecoration(color: palette.surfaceCard, border: Border.all(color: palette.dividerSubtle), borderRadius: BorderRadius.circular(8))`.
- Text: `palette.textPrimary`, 13 px, no weight override.
- Appears with a 120 ms fade-in (`AnimatedOpacity`); disappears instantly on mouse-leave.

## AnimatedIndicatorBar

### Public API

New file: `packages/screen_recorder/lib/ui/widgets/animated_indicator_bar.dart`.

```dart
class AnimatedIndicatorBar extends StatelessWidget {
  const AnimatedIndicatorBar({
    super.key,
    required this.selectedIndex,
    required this.itemCount,
    required this.itemHeight,
    required this.itemGap,
    this.barWidth = 3,
    this.barHeightFraction = 0.6,
    this.leftInset = 4,
  });

  final int selectedIndex;     // -1 = no selection (bar fades out)
  final int itemCount;
  final double itemHeight;
  final double itemGap;
  final double barWidth;
  final double barHeightFraction;
  final double leftInset;
}
```

### Layout

The widget sizes itself to the full column footprint:
- Width: `leftInset + barWidth` (e.g. `4 + 3 = 7 px`).
- Height: `itemHeight * itemCount + itemGap * (itemCount - 1)`.

Internally renders a single `Positioned` accent rectangle whose `top` value targets the selected item's vertical center, offset by half the bar height:

```dart
double _targetTop(int index) {
  final itemCenterY = (itemHeight + itemGap) * index + itemHeight / 2;
  final barHeight = itemHeight * barHeightFraction;
  return itemCenterY - barHeight / 2;
}
```

The bar rectangle:
- Width: `barWidth`.
- Height: `itemHeight * barHeightFraction`.
- Left: `leftInset`.
- Color: `palette.accent`.
- Border radius: `barWidth / 2` (fully rounded ends).

### Animation

Uses `TweenAnimationBuilder<double>` keyed on `selectedIndex`, tweening `top` from the previous target to the new one.

- **Curve:** a custom `_SpringCurve` that interpolates a spring's normalized 0→1 progression with ~12% overshoot. Implemented as `transform(t)` using `1 + (e^(-6t) * (-cos(12t)))` clamped to settle at 1.0 after t≥0.9.
- **Duration:** 320 ms.
- **First-mount jump:** when the widget is first built (`_previousIndex` is null), the initial `TweenAnimationBuilder` uses `Duration.zero` so the bar snaps to its initial spot without sliding from index 0. Subsequent rebuilds use the spring duration.

### Empty state

When `selectedIndex < 0`, wrap the Positioned in an `AnimatedOpacity(opacity: 0, duration: 200ms, curve: Curves.easeOutCubic)`. When it returns to ≥ 0, opacity 1.

## Rail Integration

`packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` rail builder.

### Old shape (to be replaced)

```dart
SizedBox(
  width: 56,
  child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        for (final t in InspectorTab.values) ...[
          _RailButton(tab: t, isSelected: t == selected, onTap: () => onSelect(t)),
          const SizedBox(height: 8),
        ],
      ],
    ),
  ),
);
```

### New shape

```dart
const railWidth = 56.0;
const railVerticalPad = 12.0;
const itemHeight = 40.0;
const itemGap = 8.0;

return SizedBox(
  width: railWidth,
  child: Padding(
    padding: const EdgeInsets.symmetric(vertical: railVerticalPad),
    child: Stack(
      children: [
        AnimatedIndicatorBar(
          selectedIndex: InspectorTab.values.indexOf(selected),
          itemCount: InspectorTab.values.length,
          itemHeight: itemHeight,
          itemGap: itemGap,
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in InspectorTab.values) ...[
                SpringyIconButton(
                  icon: t.icon,
                  tooltip: t.label,
                  isActive: t == selected,
                  onTap: () => onSelect(t),
                  size: itemHeight,
                ),
                if (t != InspectorTab.values.last)
                  const SizedBox(height: itemGap),
              ],
            ],
          ),
        ),
      ],
    ),
  ),
);
```

### Deletions

The following file-private classes get deleted from `inspector_panel.dart`:
- `_RailButton`
- `_AccentDot`

No other callers exist (both are private to the file).

## Files Created / Modified

**Create:**
- `packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart`
- `packages/screen_recorder/lib/ui/widgets/animated_indicator_bar.dart`
- `packages/screen_recorder/test/ui/widgets/springy_icon_button_test.dart`
- `packages/screen_recorder/test/ui/widgets/animated_indicator_bar_test.dart`

**Modify:**
- `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` — swap rail builder; delete `_RailButton` + `_AccentDot`; add new widget imports.

## Testing

### `springy_icon_button_test.dart`

- Renders the supplied icon (find.byIcon).
- Tapping fires `onTap`.
- When `isActive: true`, the icon color is `palette.accent` and background is non-transparent.
- When `isActive: false`, the icon color is `palette.textSecondary` and background is transparent.
- Hover (MouseRegion enter via `tester.createGesture(kind: PointerDeviceKind.mouse)`) triggers a scale increase. Sample after `pumpAndSettle`; assert the transform matrix's scale is strictly greater than 1.0.
- Hover exit returns scale to 1.0 (the resting target for both active and inactive — Q3's "active = like held-down press" maps to `resting = 1.0`, `hover = 1.04`).

### `animated_indicator_bar_test.dart`

- Renders one Positioned-laid child colored `palette.accent`.
- When `selectedIndex` changes 1 → 3, the bar's `top` tweens. Sample at three points: start (matches old target), mid (between old and new), end (matches new target).
- When `selectedIndex` is `-1`, the bar's opacity is 0.
- First mount with `selectedIndex: 2` snaps without animation; the bar is at the index-2 target after a single `pump()` with no time elapsed.

### `springy_icon_button_tooltip_test.dart` (separate file)

- Hover for 600 ms → tooltip overlay appears.
- The overlay's right edge is ≤ the button's left edge (positioned to the left).
- Hover-exit → tooltip is removed within one frame.

### Manual verification

- Open editor → indicator bar visible at left of active tab.
- Click through all 7 tabs → bar spring-animates with visible overshoot.
- Hover each button → subtle scale-up and color brighten.
- Hover the active button → slight extra bump.
- Press-down → quick dip in scale, springs back on release.
- Hover any button >500ms → tooltip pops to its LEFT, dark chip styling.
- Accent dot badge is gone.

## Open Risks

- **Spring on `top` via TweenAnimationBuilder vs `AnimationController`.** A `TweenAnimationBuilder` with a custom curve gives the spring look without managing a controller, but the curve approximates rather than physically simulates. If the overshoot feels off in-app, we swap to an `AnimationController.animateWith(SpringSimulation)` driving the bar's top via a `Listenable`. Acceptable to tune the curve constant first, controller upgrade as fallback.
- **`_LeftTooltip` overlay routing.** `CompositedTransformFollower` paints into the nearest Overlay (the root navigator's, by default). If the inspector ever ends up inside a `Navigator` of its own (e.g. modal sheet), the tooltip will float relative to that. Acceptable for now — the inspector lives in the editor's root.
- **Mouse-only.** `MouseRegion` triggers only fire for mouse pointers. On a touch trackpad gesture, hover-related effects won't fire; press-down still does via tap. Acceptable on macOS desktop.
