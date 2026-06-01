# Springy Inspector Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inspector tab rail's `_RailButton` + `_AccentDot` with two new reusable widgets — `SpringyIconButton` (spring-physics scale on hover/press, "stuck enlarged" active state, custom left-anchored tooltip) and `AnimatedIndicatorBar` (vertical accent bar that spring-translates between selections). The top-right accent dot badge goes away.

**Architecture:** Two small focused widgets under `packages/screen_recorder/lib/ui/widgets/`. The inspector rail composes them in a `Stack` — the bar painted first (left edge), the Column of buttons painted on top. The button owns its own hover/press `AnimationController` driving a `SpringSimulation` for scale. The bar derives `top` from `selectedIndex` and tweens with a custom spring curve.

**Tech Stack:** Dart 3 / Flutter (Material 3), `SpringSimulation` / `AnimationController` / `TweenAnimationBuilder` (built-in), Riverpod (already in use), FVM 3.41.5 (`~/fvm/versions/3.41.5/bin/flutter`).

**Spec:** `docs/superpowers/specs/2026-06-01-springy-rail-design.md`.

---

## File Structure

**Create:**
- `packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart` — the button widget + private `_LeftTooltip` (kept in the same file since the tooltip is intrinsic to the button's interaction model and not reused elsewhere).
- `packages/screen_recorder/lib/ui/widgets/animated_indicator_bar.dart` — the bar widget + private `_SpringCurve`.
- `packages/screen_recorder/test/ui/widgets/springy_icon_button_test.dart`
- `packages/screen_recorder/test/ui/widgets/springy_icon_button_tooltip_test.dart`
- `packages/screen_recorder/test/ui/widgets/animated_indicator_bar_test.dart`

**Modify:**
- `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` — replace the rail builder; delete `_RailButton` and `_AccentDot`; add imports for the two new widgets.

---

## Tasks

### Task 1: `AnimatedIndicatorBar` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/animated_indicator_bar.dart`
- Test: `packages/screen_recorder/test/ui/widgets/animated_indicator_bar_test.dart`

Doing the bar first because it has no dependency on the button — it's a pure positioning widget. The button (Task 2) is more involved and gets a clean foundation to compose against.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/ui/widgets/animated_indicator_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/animated_indicator_bar.dart';

const _itemHeight = 40.0;
const _itemGap = 8.0;
const _itemCount = 7;

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('paints exactly one accent-colored rectangle', (tester) async {
    await tester.pumpWidget(_host(const AnimatedIndicatorBar(
      selectedIndex: 0,
      itemCount: _itemCount,
      itemHeight: _itemHeight,
      itemGap: _itemGap,
    )));
    final accent = AppPalette.midnight.accent;
    final containers = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((d) {
      final dec = d.decoration;
      return dec is BoxDecoration && dec.color == accent;
    });
    expect(containers.length, 1);
  });

  testWidgets('initial mount snaps to selectedIndex without animation',
      (tester) async {
    await tester.pumpWidget(_host(const AnimatedIndicatorBar(
      selectedIndex: 3,
      itemCount: _itemCount,
      itemHeight: _itemHeight,
      itemGap: _itemGap,
    )));
    // Single pump (no time elapse). Should already be at index-3 target.
    final positioned = tester.widget<Positioned>(find.byType(Positioned));
    final centerY = (_itemHeight + _itemGap) * 3 + _itemHeight / 2;
    final expectedTop = centerY - (_itemHeight * 0.6) / 2;
    expect(positioned.top, closeTo(expectedTop, 0.5));
  });

  testWidgets('changing selectedIndex animates top toward the new target',
      (tester) async {
    int selected = 1;
    late StateSetter setter;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, ss) {
      setter = ss;
      return AnimatedIndicatorBar(
        selectedIndex: selected,
        itemCount: _itemCount,
        itemHeight: _itemHeight,
        itemGap: _itemGap,
      );
    })));

    final centerYFor = (int i) => (_itemHeight + _itemGap) * i + _itemHeight / 2;
    final topFor = (int i) => centerYFor(i) - (_itemHeight * 0.6) / 2;

    final startTop = tester.widget<Positioned>(find.byType(Positioned)).top;
    expect(startTop, closeTo(topFor(1), 0.5));

    setter(() => selected = 5);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final midTop = tester.widget<Positioned>(find.byType(Positioned)).top!;
    expect(midTop, greaterThan(topFor(1)));
    expect(midTop, lessThan(topFor(5)));

    await tester.pumpAndSettle();
    final endTop = tester.widget<Positioned>(find.byType(Positioned)).top;
    expect(endTop, closeTo(topFor(5), 1.5),
        reason: 'spring may overshoot then settle within tolerance');
  });

  testWidgets('selectedIndex < 0 fades opacity to 0', (tester) async {
    int selected = 2;
    late StateSetter setter;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, ss) {
      setter = ss;
      return AnimatedIndicatorBar(
        selectedIndex: selected,
        itemCount: _itemCount,
        itemHeight: _itemHeight,
        itemGap: _itemGap,
      );
    })));

    setter(() => selected = -1);
    await tester.pumpAndSettle();
    final opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 0.0);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/animated_indicator_bar_test.dart`
Expected: FAIL with `"Target of URI doesn't exist: 'package:screen_recorder/ui/widgets/animated_indicator_bar.dart'"`.

- [ ] **Step 3: Implement the widget**

```dart
// packages/screen_recorder/lib/ui/widgets/animated_indicator_bar.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Vertical accent bar that spring-translates between row positions in
/// a stacked column of equal-height items. Renders one rectangle whose
/// top edge tweens to the center of [selectedIndex]'s row.
///
/// The widget paints itself the size of the full column footprint:
///   width  = leftInset + barWidth
///   height = itemHeight * itemCount + itemGap * (itemCount - 1)
///
/// Used by the inspector rail today; reusable wherever a vertical tab
/// strip needs an accent indicator (settings tabs, future side rails).
class AnimatedIndicatorBar extends StatefulWidget {
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

  /// -1 means "no selection" — the bar fades out.
  final int selectedIndex;
  final int itemCount;
  final double itemHeight;
  final double itemGap;
  final double barWidth;

  /// Bar's vertical extent as a fraction of [itemHeight]. 0.6 ≈ 24 px
  /// on a 40 px row.
  final double barHeightFraction;

  /// Distance from the widget's left edge to the bar's left edge.
  final double leftInset;

  @override
  State<AnimatedIndicatorBar> createState() => _AnimatedIndicatorBarState();
}

class _AnimatedIndicatorBarState extends State<AnimatedIndicatorBar> {
  int? _previousIndex;

  @override
  void didUpdateWidget(covariant AnimatedIndicatorBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _previousIndex = oldWidget.selectedIndex;
    }
  }

  double _targetTop(int index) {
    final centerY = (widget.itemHeight + widget.itemGap) * index +
        widget.itemHeight / 2;
    final barHeight = widget.itemHeight * widget.barHeightFraction;
    return centerY - barHeight / 2;
  }

  @override
  Widget build(BuildContext context) {
    final barHeight = widget.itemHeight * widget.barHeightFraction;
    final width = widget.leftInset + widget.barWidth;
    final height = widget.itemHeight * widget.itemCount +
        widget.itemGap * (widget.itemCount - 1);

    final isVisible = widget.selectedIndex >= 0;
    final targetTop = isVisible ? _targetTop(widget.selectedIndex) : 0.0;
    final beginTop =
        _previousIndex != null ? _targetTop(_previousIndex!) : targetTop;
    // First mount snaps; subsequent rebuilds spring.
    final duration = _previousIndex == null
        ? Duration.zero
        : const Duration(milliseconds: 320);

    return SizedBox(
      width: width,
      height: height,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        opacity: isVisible ? 1.0 : 0.0,
        child: Stack(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: beginTop, end: targetTop),
              duration: duration,
              curve: _SpringCurve(),
              builder: (context, top, _) {
                return Positioned(
                  top: top,
                  left: widget.leftInset,
                  width: widget.barWidth,
                  height: barHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.palette.accent,
                      borderRadius: BorderRadius.circular(widget.barWidth / 2),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Spring-ish curve with ~12% overshoot that settles by t≈0.9. Cheaper
/// than a SpringSimulation-driven AnimationController for a single
/// scalar tween; if the look ever needs tuning, this is the place.
class _SpringCurve extends Curve {
  const _SpringCurve();

  @override
  double transform(double t) {
    if (t >= 1.0) return 1.0;
    // Damped cosine: 1 - exp(-6t) * cos(12t). Crosses 1.0 ~t=0.18, peaks
    // near 1.12 around t=0.32, settles by t≈0.9.
    final v = 1.0 - math.exp(-6 * t) * math.cos(12 * t);
    return v;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/animated_indicator_bar_test.dart`
Expected: PASS — 4 tests.

If the "changing selectedIndex animates" test fails because mid-tween sampling lands at the resting position, the curve may settle faster than 160 ms. Adjust the mid-pump duration to 80 ms or change the assertion tolerance — but only after re-confirming the curve produces visible motion.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/animated_indicator_bar.dart \
        packages/screen_recorder/test/ui/widgets/animated_indicator_bar_test.dart
git commit -m "feat(app): add AnimatedIndicatorBar — vertical accent rail indicator"
```

---

### Task 2: `SpringyIconButton` core widget (no tooltip yet)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart`
- Test: `packages/screen_recorder/test/ui/widgets/springy_icon_button_test.dart`

Split the button into two tasks: this one builds the spring scale + visual states (icon color, background tint, active state). Task 3 layers the `_LeftTooltip` on top. Reasoning: the tooltip is a self-contained overlay concern; testing it requires `runAsync` + timers + overlay finders that don't compose with the basic widget rendering tests.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/ui/widgets/springy_icon_button_test.dart
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('renders the supplied icon', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.mouse), findsOneWidget);
  });

  testWidgets('tap fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(SpringyIconButton));
    expect(taps, 1);
  });

  testWidgets('inactive icon color is textSecondary', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.mouse));
    expect(icon.color, AppPalette.midnight.textSecondary);
  });

  testWidgets('active icon color is accent', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: true,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byIcon(Icons.mouse));
    expect(icon.color, AppPalette.midnight.accent);
  });

  testWidgets('active background uses accentMuted (non-transparent)',
      (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: true,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final accentMuted = AppPalette.midnight.accentMuted;
    final found = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .any((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.color == accentMuted;
    });
    expect(found, isTrue);
  });

  testWidgets('inactive background is transparent', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    final found = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .any((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.color == Colors.transparent;
    });
    expect(found, isTrue);
  });

  testWidgets('hover triggers a scale > 1.0', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pumpAndSettle();

    // The spring overshoots ~10% above target; assert strictly > 1.0.
    final transform =
        tester.widget<Transform>(find.byType(Transform).first).transform;
    expect(transform.entry(0, 0), greaterThan(1.0));
  });

  testWidgets('hover exit returns scale to 1.0', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pumpAndSettle();
    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();

    final transform =
        tester.widget<Transform>(find.byType(Transform).first).transform;
    expect(transform.entry(0, 0), closeTo(1.0, 0.01));
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/springy_icon_button_test.dart`
Expected: FAIL with `"Target of URI doesn't exist"`.

- [ ] **Step 3: Implement the button (core only, NO tooltip yet)**

```dart
// packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Reusable icon button with a spring-physics hover/press response.
/// "Active" buttons retain a held-down look (tinted background +
/// accent icon color) — the spring response is layered on top of that
/// for hover and press confirmation.
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

  @override
  State<SpringyIconButton> createState() => _SpringyIconButtonState();
}

class _SpringyIconButtonState extends State<SpringyIconButton>
    with SingleTickerProviderStateMixin {
  static const _spring = SpringDescription(
    mass: 1.0,
    stiffness: 220.0,
    damping: 16.0,
  );

  late final AnimationController _scaleAc = AnimationController.unbounded(
    vsync: this,
    value: 1.0,
  );

  bool _hovered = false;
  bool _pressed = false;

  @override
  void dispose() {
    _scaleAc.dispose();
    super.dispose();
  }

  // Targets per state, branching on isActive.
  double get _restScale => 1.0;
  double get _hoverScale => widget.isActive ? 1.04 : 1.08;
  double get _pressScale => 0.94;

  double get _targetScale {
    if (_pressed) return _pressScale;
    if (_hovered) return _hoverScale;
    return _restScale;
  }

  void _animateToTarget() {
    final sim =
        SpringSimulation(_spring, _scaleAc.value, _targetScale, _scaleAc.velocity);
    _scaleAc.animateWith(sim);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final iconColor =
        widget.isActive ? palette.accent : palette.textSecondary;
    final bgColor = _backgroundColor(palette);

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        _animateToTarget();
      },
      onExit: (_) {
        setState(() {
          _hovered = false;
          _pressed = false;
        });
        _animateToTarget();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          setState(() => _pressed = true);
          _animateToTarget();
        },
        onTapUp: (_) {
          setState(() => _pressed = false);
          _animateToTarget();
        },
        onTapCancel: () {
          setState(() => _pressed = false);
          _animateToTarget();
        },
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _scaleAc,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: iconColor,
            ),
          ),
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAc.value,
              child: child,
            );
          },
        ),
      ),
    );
  }

  Color _backgroundColor(AppPalette palette) {
    // Base alpha is whatever AppPalette.accentMuted encodes (~0.18).
    // Inactive: 0 (transparent) at rest; 0.4× at hover/press.
    // Active: 1.0× at rest; 1.1× at hover/press.
    // We compose by alpha-scaling the accent color.
    final hovering = _hovered || _pressed;
    final double alphaMultiplier;
    if (widget.isActive) {
      alphaMultiplier = hovering ? 1.1 : 1.0;
    } else {
      alphaMultiplier = hovering ? 0.4 : 0.0;
    }
    if (alphaMultiplier == 0.0) return Colors.transparent;
    return palette.accent.withValues(alpha: 0.18 * alphaMultiplier);
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/springy_icon_button_test.dart`
Expected: PASS — 8 tests.

NOTE — the "active background uses accentMuted (non-transparent)" test asserts the color equals `AppPalette.midnight.accentMuted` exactly. The implementation produces `palette.accent.withValues(alpha: 0.18)`. These ARE the same color (per the `AppPalette.midnight` constant definition: `accentMuted: Color(0x2E7C6CFF)` which is `accent` at alpha 0.18). If the test fails because of a one-off rounding (alpha 0x2E vs 0x2D), adjust the test to use `closeTo` on the alpha channel or compare components separately.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart \
        packages/screen_recorder/test/ui/widgets/springy_icon_button_test.dart
git commit -m "feat(app): SpringyIconButton with spring scale + active-stuck visuals"
```

---

### Task 3: `_LeftTooltip` — add left-anchored tooltip to `SpringyIconButton`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart`
- Test: `packages/screen_recorder/test/ui/widgets/springy_icon_button_tooltip_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/ui/widgets/springy_icon_button_tooltip_test.dart
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('tooltip text appears after 500ms hover', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));

    // Before delay: no tooltip yet.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Cursor'), findsNothing);

    // After delay: tooltip visible.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsOneWidget);
  });

  testWidgets('tooltip overlay sits to the LEFT of the button',
      (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final buttonRect =
        tester.getRect(find.byType(SpringyIconButton));
    final tooltipRect = tester.getRect(find.text('Cursor'));
    expect(tooltipRect.right, lessThanOrEqualTo(buttonRect.left),
        reason: 'tooltip should be entirely left of the button');
  });

  testWidgets('hover-exit removes the tooltip', (tester) async {
    await tester.pumpWidget(_host(SpringyIconButton(
      icon: Icons.mouse,
      tooltip: 'Cursor',
      isActive: false,
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SpringyIconButton)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsOneWidget);

    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsNothing);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/springy_icon_button_tooltip_test.dart`
Expected: FAIL — no tooltip exists yet; the existing `MouseRegion` in Task 2 doesn't show any text.

- [ ] **Step 3: Wrap the button's content in `_LeftTooltip`**

Edit `packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart`.

Add a `LayerLink` field to the state and use it to anchor the tooltip overlay. Modify `_SpringyIconButtonState.build` so the GestureDetector's child is wrapped in a `CompositedTransformTarget(link: _link, child: ...)`, and add the `_LeftTooltip` widget that owns the overlay lifecycle.

Add this to `_SpringyIconButtonState`:

```dart
final LayerLink _link = LayerLink();
final GlobalKey<_LeftTooltipState> _tooltipKey = GlobalKey<_LeftTooltipState>();
```

Wrap the build's outer `MouseRegion` so that:
- `onEnter` ALSO calls `_tooltipKey.currentState?.scheduleShow()`.
- `onExit` ALSO calls `_tooltipKey.currentState?.cancel()`.
- `onTapDown` calls `_tooltipKey.currentState?.cancel()` (so the tooltip doesn't pop while you're clicking).

The build returns `_LeftTooltip(key: _tooltipKey, link: _link, message: widget.tooltip, child: <existing MouseRegion+GestureDetector tree wrapped in CompositedTransformTarget(link: _link, child: …)>)`.

Append this widget to the same file (below the `_SpringyIconButtonState` class):

```dart
/// Tooltip that pops to the LEFT of its child after a hover delay.
/// Owns its own [OverlayEntry] lifecycle; parent triggers
/// [scheduleShow]/[cancel] via the [GlobalKey].
class _LeftTooltip extends StatefulWidget {
  const _LeftTooltip({
    super.key,
    required this.link,
    required this.message,
    required this.child,
    this.delay = const Duration(milliseconds: 500),
  });

  final LayerLink link;
  final String message;
  final Widget child;
  final Duration delay;

  @override
  State<_LeftTooltip> createState() => _LeftTooltipState();
}

class _LeftTooltipState extends State<_LeftTooltip> {
  Timer? _showTimer;
  OverlayEntry? _entry;

  void scheduleShow() {
    _showTimer?.cancel();
    _showTimer = Timer(widget.delay, _show);
  }

  void cancel() {
    _showTimer?.cancel();
    _showTimer = null;
    _entry?.remove();
    _entry = null;
  }

  void _show() {
    if (_entry != null) return;
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(builder: (ctx) {
      final palette = context.palette;
      return Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: widget.link,
          targetAnchor: Alignment.centerLeft,
          followerAnchor: Alignment.centerRight,
          offset: const Offset(-8, 0),
          showWhenUnlinked: false,
          child: AnimatedOpacity(
            opacity: 1,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: palette.surfaceCard,
                  border: Border.all(color: palette.dividerSubtle),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
    overlay.insert(entry);
    _entry = entry;
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
```

Also add to the imports at the top of the file:

```dart
import 'dart:async';
```

The final `_SpringyIconButtonState.build` method shape becomes:

```dart
@override
Widget build(BuildContext context) {
  final palette = context.palette;
  final iconColor =
      widget.isActive ? palette.accent : palette.textSecondary;
  final bgColor = _backgroundColor(palette);

  return _LeftTooltip(
    key: _tooltipKey,
    link: _link,
    message: widget.tooltip,
    child: CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _hovered = true);
          _animateToTarget();
          _tooltipKey.currentState?.scheduleShow();
        },
        onExit: (_) {
          setState(() {
            _hovered = false;
            _pressed = false;
          });
          _animateToTarget();
          _tooltipKey.currentState?.cancel();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            setState(() => _pressed = true);
            _animateToTarget();
            _tooltipKey.currentState?.cancel();
          },
          onTapUp: (_) {
            setState(() => _pressed = false);
            _animateToTarget();
          },
          onTapCancel: () {
            setState(() => _pressed = false);
            _animateToTarget();
          },
          onTap: widget.onTap,
          child: AnimatedBuilder(
            animation: _scaleAc,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: iconColor,
              ),
            ),
            builder: (context, child) {
              return Transform.scale(
                scale: _scaleAc.value,
                child: child,
              );
            },
          ),
        ),
      ),
    ),
  );
}
```

- [ ] **Step 4: Run the tooltip tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/springy_icon_button_tooltip_test.dart`
Expected: PASS — 3 tests.

Also re-run the Task 2 tests to confirm no regression:
Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/springy_icon_button_test.dart`
Expected: PASS — 8 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/springy_icon_button.dart \
        packages/screen_recorder/test/ui/widgets/springy_icon_button_tooltip_test.dart
git commit -m "feat(app): SpringyIconButton — left-anchored tooltip with hover delay"
```

---

### Task 4: Rail integration

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`

- [ ] **Step 1: Add imports**

Open `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`. Add to the top alongside the existing imports:

```dart
import '../animated_indicator_bar.dart';
import '../springy_icon_button.dart';
```

- [ ] **Step 2: Replace the rail builder**

Find the existing rail-building code (around `class _Rail extends StatelessWidget` / `_RailButton` invocation). The Column-of-`_RailButton`s sits inside a `SizedBox(width: 56, …)`. Replace the inner build with the new Stack composition.

Locate `build(BuildContext context)` of the class that contains the `for (final t in InspectorTab.values)` loop (it's the `_Rail` widget). Replace its return with:

```dart
@override
Widget build(BuildContext context) {
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
}
```

The `_Rail` class likely has `final InspectorTab selected` and `final ValueChanged<InspectorTab> onSelect` fields already — use them as-is. If the existing field names are slightly different (e.g. `currentTab` / `onTabSelected`), substitute them in the new code.

- [ ] **Step 3: Delete `_RailButton` and `_AccentDot`**

Find the `class _RailButton extends StatelessWidget` (around line 218) and `class _AccentDot extends StatelessWidget` (around line 260) in the same file. Delete both class definitions entirely. They're file-private so no callers exist.

- [ ] **Step 4: Verify analyzer + tests**

Run:
```bash
~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```
Expected: Analyzer clean (no new errors). Tests: same baseline as before (pre-existing failures aside).

If a test in `test/ui/inspector/` fails because it used `find.byType(_RailButton)`, those finders no longer match. Update the failing test to use `find.byType(SpringyIconButton)` and `find.text(<tab label>)` instead.

- [ ] **Step 5: Manual smoke test**

Hot-restart the app via the agent-wires probe. Open a recording → editor. Confirm:
- Inspector rail still renders 7 tabs in the right order.
- Clicking each tab switches the active panel (Background, Cursor, Camera, …).
- The vertical indicator bar appears at the LEFT of the active icon and spring-animates between selections.
- The top-right accent dot is gone.
- Hovering each button scales it slightly with overshoot.
- Hovering for >500ms pops the tooltip to the LEFT.
- The active button stays at its tinted background even when the mouse is elsewhere.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart
git commit -m "refactor(app): inspector rail uses SpringyIconButton + AnimatedIndicatorBar"
```

---

### Task 5: Manual end-to-end verification

**Files:** none — verification only.

- [ ] **Step 1: Hot-restart**

If the app is running, hot-restart. Otherwise launch via `~/fvm/versions/3.41.5/bin/flutter run -d macos` from the repo root.

- [ ] **Step 2: Rail behavior**

Open a recording → editor. Walk through the inspector tabs:
- Click each of the 7 tabs in sequence. Bar spring-translates with visible overshoot.
- Hover an inactive button: scale-up with subtle overshoot, background tint appears.
- Hover the active button: a slight extra bump on top of the active tint.
- Press-down on any button: quick scale dip (~0.94), springs back on release.
- Hover a button >500ms: tooltip appears to the LEFT.
- Move cursor off the button: tooltip disappears immediately.
- Click a button while another is active: bar springs to the new position; the previously-active button loses its tint smoothly.

- [ ] **Step 3: Across palettes**

Open Settings → Appearance → Theme playground. Pick each palette (Midnight, Carbon, Obsidian) and confirm:
- The indicator bar uses the new palette's `accent`.
- The tooltip chip uses the new palette's `surfaceCard` + `dividerSubtle`.
- Active button tint matches the new palette's `accentMuted`.

Return to Midnight before finishing.

- [ ] **Step 4: No commit**

Verification only. If anything fails, fix the offending widget (likely in Task 2/3) and re-run from Step 1.

---

## Done

After Task 5 passes, hand off to `superpowers:finishing-a-development-branch` to merge.
