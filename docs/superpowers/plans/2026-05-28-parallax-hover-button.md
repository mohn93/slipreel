# Parallax Hover Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small, cursor-tracked parallax offset to the child (icon + text) inside `SpringHoverButton`, layered on top of the existing pill magnetic-lean. All six recording-bar buttons inherit the effect automatically.

**Architecture:** Single-file change to `SpringHoverButton` adding two new springs (`_innerDx`, `_innerDy`, stiffness 300 / zeta 0.9), threaded through the existing ticker + settle-check, and rendered via a `Transform.translate` wrapping `widget.child`. Hover-enter/move retarget the inner springs to `(rel * 0.06)` clamped to ±4 × ±3 px; exit targets 0. Child starts at offset 0 (not at the cursor entry point), so it springs gently into the parallax position rather than flying in. No public API change, no caller migrations.

**Tech Stack:** Flutter, Dart, `flutter/scheduler.dart` Ticker, `flutter_test` widget-test framework + `TestPointer`.

**Spec:** `docs/superpowers/specs/2026-05-28-parallax-hover-button-design.md`

**Branch:** `feat/parallax-hover-button` (already checked out off `main`)

---

## File Structure

- **Modify:** `packages/screen_recorder/lib/ui/bar/spring_hover_button.dart` — add two springs to the state, thread them through the ticker + settle-check + lifecycle methods, and wrap `widget.child` in a `Transform.translate` inside the Stack.
- **Create:** `packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart` — first test file for this widget. Pins the inner-parallax contract: idle offset is zero, hovering produces a same-sign offset within the clamp, exit trends the offset back toward zero.

Single file modified, single test file created. Six call sites in `packages/screen_recorder/lib/ui/bar/recording_bar.dart` are NOT modified (they pick up the effect automatically via the unchanged constructor).

---

## Task 1: Pin the existing idle behavior (regression guard)

**Files:**
- Test: `packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart` (create)

**Rationale:** No test exists for `SpringHoverButton` today. Before adding the new parallax behavior, drop in a test that pins the BEFORE behavior — "child sits at its layout position when not hovered" — so we have a regression anchor. Confirm it passes against the unmodified widget. The failing/new-behavior tests come in Task 3.

- [ ] **Step 1: Write the idle-behavior test**

Create `packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';

const Key kChildKey = Key('inner-child');

Widget _harness({VoidCallback? onTap}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 120,
          height: 40,
          child: SpringHoverButton(
            onTap: onTap,
            child: const Center(
              child: Text('Hello', key: kChildKey),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Returns the global (screen-space) top-left of the inner child as
/// rendered. Useful for asserting how far the child has shifted from its
/// layout position.
Offset _childTopLeft(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(find.byKey(kChildKey));
  return box.localToGlobal(Offset.zero);
}

void main() {
  group('SpringHoverButton', () {
    testWidgets('child sits at its layout position when not hovered',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // Without hover, the child should be at its layout position. We
      // capture its position twice across a few ticker frames and assert
      // it doesn't drift (no idle motion).
      final p0 = _childTopLeft(tester);
      await tester.pump(const Duration(milliseconds: 200));
      final p1 = _childTopLeft(tester);

      expect((p1 - p0).distance, lessThan(0.5),
          reason: 'child must be stationary when not hovered');
    });
  });
}
```

- [ ] **Step 2: Run the test against the unmodified widget**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/spring_hover_button_test.dart -r expanded`
Expected: PASS — the unmodified widget already keeps the child stationary when not hovered. This is the regression anchor for Task 3.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart
git commit -m "test(app): pin idle position of SpringHoverButton child"
```

---

## Task 2: Add the inner-parallax springs and render path (no behavior change yet)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/spring_hover_button.dart`

**Rationale:** Introduce the two new springs and the `Transform.translate` around the child WITHOUT changing the targets. The springs stay parked at 0 (their initial value), the translate renders as a no-op, and existing behavior is identical. This isolates the wiring change from the behavior change so each step is reviewable and reversible. Task 3 then sets the targets to produce the actual parallax.

- [ ] **Step 1: Add the two new spring fields**

In `packages/screen_recorder/lib/ui/bar/spring_hover_button.dart`, locate the `_SpringHoverButtonState` class (around line 61). Add two fields next to `_dx`/`_dy` (around line 70):

```dart
  // Inner-content parallax. The child (icon + text) tracks the cursor at a
  // smaller range than the pill, with a calmer spring (zeta 0.9 — no
  // perceptible overshoot), producing a "depth" effect: pill leans, child
  // settles. See docs/superpowers/specs/2026-05-28-parallax-hover-button-design.md.
  final _innerDx = _Spring(0, stiffness: 300, zeta: 0.9);
  final _innerDy = _Spring(0, stiffness: 300, zeta: 0.9);
```

So the field block reads (existing + new together):

```dart
  final _reveal = _Spring(0, stiffness: 380, zeta: 1.0);
  final _scale = _Spring(0.6, stiffness: 340, zeta: 0.6);
  final _press = _Spring(0, stiffness: 520, zeta: 1.0);
  final _dx = _Spring(0, stiffness: 300, zeta: 0.58);
  final _dy = _Spring(0, stiffness: 300, zeta: 0.58);
  // Inner-content parallax. The child (icon + text) tracks the cursor at a
  // smaller range than the pill, with a calmer spring (zeta 0.9 — no
  // perceptible overshoot), producing a "depth" effect: pill leans, child
  // settles. See docs/superpowers/specs/2026-05-28-parallax-hover-button-design.md.
  final _innerDx = _Spring(0, stiffness: 300, zeta: 0.9);
  final _innerDy = _Spring(0, stiffness: 300, zeta: 0.9);
```

- [ ] **Step 2: Thread the new springs through the ticker and settle-check**

In `_onTick` (around lines 93-109), replace the spring-iteration list and the settled-check:

Replace:
```dart
    for (final s in [_reveal, _scale, _press, _dx, _dy]) {
      s.tick(dt);
    }
    setState(() {});
    if (_reveal.settled &&
        _scale.settled &&
        _press.settled &&
        _dx.settled &&
        _dy.settled) {
      _ticker.stop();
    }
```

With:
```dart
    for (final s in [_reveal, _scale, _press, _dx, _dy, _innerDx, _innerDy]) {
      s.tick(dt);
    }
    setState(() {});
    if (_reveal.settled &&
        _scale.settled &&
        _press.settled &&
        _dx.settled &&
        _dy.settled &&
        _innerDx.settled &&
        _innerDy.settled) {
      _ticker.stop();
    }
```

- [ ] **Step 3: Wrap `widget.child` in a `Transform.translate` inside the Stack**

In `build` (around lines 170-213), the Stack currently is:

```dart
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: reveal,
                  child: Transform.translate(
                    offset: Offset(_dx.value, _dy.value),
                    child: Transform.scale(
                      scale: _scale.value.clamp(0.0, 1.2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: (0.07 + 0.12 * _press.value).clamp(0.0, 0.22),
                          ),
                          borderRadius:
                              BorderRadius.circular(widget.borderRadius),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            widget.child,
          ],
        ),
```

Replace the bare `widget.child,` at the end of the children list with:

```dart
            Transform.translate(
              offset: Offset(_innerDx.value, _innerDy.value),
              child: widget.child,
            ),
```

Final Stack:

```dart
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: reveal,
                  child: Transform.translate(
                    offset: Offset(_dx.value, _dy.value),
                    child: Transform.scale(
                      scale: _scale.value.clamp(0.0, 1.2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: (0.07 + 0.12 * _press.value).clamp(0.0, 0.22),
                          ),
                          borderRadius:
                              BorderRadius.circular(widget.borderRadius),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(_innerDx.value, _innerDy.value),
              child: widget.child,
            ),
          ],
        ),
```

- [ ] **Step 4: Verify analyze + existing tests still pass**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/bar/spring_hover_button.dart test/ui/bar/spring_hover_button_test.dart`
Expected: No issues found (the new fields are used; the Transform.translate is well-formed).

Run: `cd packages/screen_recorder && flutter test test/ui/bar/spring_hover_button_test.dart -r expanded`
Expected: PASS — the idle-position test from Task 1 still passes (springs at 0 → translate is no-op → child stationary).

Run: `cd packages/screen_recorder && flutter test`
Expected: full app suite green (matches the current baseline reported for `main` — 215 passed + 14 skipped).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/spring_hover_button.dart
git commit -m "refactor(app): scaffold inner-parallax springs in SpringHoverButton (no behavior yet)"
```

---

## Task 3: Wire the inner-parallax targets and pin the new behavior

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/spring_hover_button.dart` (lifecycle methods only)
- Modify: `packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart` (add hover + exit tests)

**Rationale:** Now drive the inner springs from the pointer events. Targets: `(rel.dx * 0.06).clamp(-4.0, 4.0)` / `(rel.dy * 0.06).clamp(-3.0, 3.0)` on enter+hover; `0` on exit. Tests pin direction + clamp + settle-on-exit (not pixel-perfect spring curves).

- [ ] **Step 1: Write the failing hover-direction + clamp test**

Add this test inside the existing `group('SpringHoverButton', () { ... })` in `packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart`:

```dart
    testWidgets(
        'hovering up-and-right shifts the child up-and-right within clamp',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final layoutTopLeft = _childTopLeft(tester);
      final buttonCentre = tester.getCenter(find.byType(SpringHoverButton));

      // Hover at the button's top-right corner. In centre-relative coords
      // that's (+w/2, -h/2) → positive dx, negative dy → child should shift
      // toward upper-right (positive dx, negative dy from its layout pos).
      final topRight = Offset(buttonCentre.dx + 50, buttonCentre.dy - 16);

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: topRight);
      addTearDown(gesture.removePointer);

      // Let the inner spring approach its target. zeta 0.9 settles quickly;
      // 250 ms of pump is plenty for the inner pair, well past their
      // critical-damping window for a small step.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final shifted = _childTopLeft(tester);
      final delta = shifted - layoutTopLeft;

      // Direction: hovering upper-right → child shifts upper-right.
      expect(delta.dx, greaterThan(0.0),
          reason: 'child should shift right when cursor is to the right');
      expect(delta.dy, lessThan(0.0),
          reason: 'child should shift up when cursor is above centre');

      // Magnitude: clamp ±4 × ±3 px. Allow a small slack for spring
      // not-fully-settled.
      expect(delta.dx.abs(), lessThanOrEqualTo(4.5),
          reason: 'inner dx clamp is ±4');
      expect(delta.dy.abs(), lessThanOrEqualTo(3.5),
          reason: 'inner dy clamp is ±3');
    });

    testWidgets('child glides back home after hover exit', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final layoutTopLeft = _childTopLeft(tester);
      final buttonCentre = tester.getCenter(find.byType(SpringHoverButton));

      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(
          location: Offset(buttonCentre.dx + 50, buttonCentre.dy - 16));
      addTearDown(gesture.removePointer);

      // Settle into hover.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final hovered = _childTopLeft(tester);
      final hoveredMag = (hovered - layoutTopLeft).distance;

      // Move pointer well off the widget to trigger exit.
      await gesture.moveTo(Offset(buttonCentre.dx + 500, buttonCentre.dy));

      // Pump a fair bit so the inner springs (and the pill) wind down.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final after = _childTopLeft(tester);
      final afterMag = (after - layoutTopLeft).distance;

      expect(afterMag, lessThan(hoveredMag * 0.4),
          reason: 'child should trend back toward its layout position on exit');
    });
```

Add the required import for `PointerDeviceKind` at the top of the file (next to the existing imports):

```dart
import 'package:flutter/gestures.dart';
```

- [ ] **Step 2: Run the tests to confirm they FAIL against Task 2's no-op render path**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/spring_hover_button_test.dart -r expanded`
Expected: FAIL — the hover-direction test fails its `delta.dx > 0` / `delta.dy < 0` expectations because the inner targets are still 0 (Task 2 only wired the render path, not the lifecycle). The exit test passes vacuously (child never moved) but that's fine — it's pinning that exit-relax keeps working once Step 3 introduces motion.

- [ ] **Step 3: Wire the inner-parallax targets in the lifecycle methods**

In `packages/screen_recorder/lib/ui/bar/spring_hover_button.dart`, modify three methods. The pill's existing `_dx`/`_dy` retarget lines are unchanged; we ADD inner retargets next to them.

`_onEnter` (around lines 119-131) — replace:

```dart
  void _onEnter(PointerEnterEvent e) {
    _hovering = true;
    widget.onHoverChanged?.call(true);
    final rel = _centreRel(e.localPosition);
    _dx.value = rel.dx; // start where the cursor entered
    _dy.value = rel.dy;
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0); // small magnetic lean
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
    _reveal.target = 1;
    _scale.value = 0.6;
    _scale.target = 1;
    _ensureTicking();
  }
```

with:

```dart
  void _onEnter(PointerEnterEvent e) {
    _hovering = true;
    widget.onHoverChanged?.call(true);
    final rel = _centreRel(e.localPosition);
    _dx.value = rel.dx; // start where the cursor entered
    _dy.value = rel.dy;
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0); // small magnetic lean
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
    // Inner-content parallax: ~50% of the pill's range, calmer spring. The
    // child does NOT start at the cursor like the pill does — it stays at
    // its layout position and springs into the (small) parallax offset.
    _innerDx.target = (rel.dx * 0.06).clamp(-4.0, 4.0);
    _innerDy.target = (rel.dy * 0.06).clamp(-3.0, 3.0);
    _reveal.target = 1;
    _scale.value = 0.6;
    _scale.target = 1;
    _ensureTicking();
  }
```

`_onHover` (around lines 133-139) — replace:

```dart
  void _onHover(PointerHoverEvent e) {
    if (!_hovering) return;
    final rel = _centreRel(e.localPosition);
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0);
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
    _ensureTicking();
  }
```

with:

```dart
  void _onHover(PointerHoverEvent e) {
    if (!_hovering) return;
    final rel = _centreRel(e.localPosition);
    _dx.target = (rel.dx * 0.12).clamp(-8.0, 8.0);
    _dy.target = (rel.dy * 0.12).clamp(-6.0, 6.0);
    _innerDx.target = (rel.dx * 0.06).clamp(-4.0, 4.0);
    _innerDy.target = (rel.dy * 0.06).clamp(-3.0, 3.0);
    _ensureTicking();
  }
```

`_onExit` (around lines 141-156) — replace:

```dart
  void _onExit(PointerExitEvent e) {
    _hovering = false;
    widget.onHoverChanged?.call(false);
    final rel = _centreRel(e.localPosition);
    final dist = rel.distance;
    final dir = dist == 0 ? const Offset(0, -1) : rel / dist;
    final s = _size;
    _dx.target = dir.dx * (s.width * 0.5 + 14);
    _dy.target = dir.dy * (s.height * 0.5 + 14);
    _reveal.target = 0;
    // Barely shrink on the way out — the fade carries the vanish, so the pill
    // never reads as a tiny scaled-down dot.
    _scale.target = 0.82;
    _press.target = 0;
    _ensureTicking();
  }
```

with:

```dart
  void _onExit(PointerExitEvent e) {
    _hovering = false;
    widget.onHoverChanged?.call(false);
    final rel = _centreRel(e.localPosition);
    final dist = rel.distance;
    final dir = dist == 0 ? const Offset(0, -1) : rel / dist;
    final s = _size;
    _dx.target = dir.dx * (s.width * 0.5 + 14);
    _dy.target = dir.dy * (s.height * 0.5 + 14);
    // Child glides home — only the pill flies off on exit.
    _innerDx.target = 0;
    _innerDy.target = 0;
    _reveal.target = 0;
    // Barely shrink on the way out — the fade carries the vanish, so the pill
    // never reads as a tiny scaled-down dot.
    _scale.target = 0.82;
    _press.target = 0;
    _ensureTicking();
  }
```

- [ ] **Step 4: Run the tests to confirm they PASS**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/spring_hover_button_test.dart -r expanded`
Expected: PASS — three tests (idle stationary, hover up-right direction + clamp, exit glides home).

- [ ] **Step 5: Run analyze + the full app suite**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/bar/spring_hover_button.dart test/ui/bar/spring_hover_button_test.dart`
Expected: No issues found.

Run: `cd packages/screen_recorder && flutter test`
Expected: full app suite green. Baseline was 215 + 14 skipped on `main`; this branch should now be 218 + 14 skipped (+3 new SpringHoverButton tests).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/spring_hover_button.dart packages/screen_recorder/test/ui/bar/spring_hover_button_test.dart
git commit -m "feat(app): inner-content parallax on SpringHoverButton hover"
```

---

## Self-Review

**Spec coverage:**
- Architecture (single-file change; new springs threaded through ticker + settle + lifecycle; `Transform.translate` around child) → Tasks 2 + 3. ✓
- Tuning (`0.06` factor, ±4×±3 clamp, stiffness 300, zeta 0.9) → Task 2 Step 1 (field declarations); Task 3 Step 3 (target retargets). ✓
- Lifecycle (enter sets target, child starts at 0; hover retargets; exit targets 0) → Task 3 Step 3 (all three methods explicitly modified, with the "child does NOT start at the cursor" comment matching the spec rationale). ✓
- Press/tap unchanged → no change to `_onTapDown`/`_release` in any task. ✓
- Hit-testing unchanged → no change to the `GestureDetector` wrapping. ✓
- All 6 callers unchanged → `recording_bar.dart` is not modified. ✓
- Tests (idle, direction + clamp, exit-glide) → Tasks 1 + 3. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". All code shown verbatim with surrounding context where the patch sits in a larger block. ✓

**Type consistency:** `_innerDx` / `_innerDy` referenced identically across declarations (Task 2 Step 1), ticker iteration (Task 2 Step 2), build (Task 2 Step 3), and retargets (Task 3 Step 3). Same factor `0.06` and clamps `-4.0..4.0` / `-3.0..3.0` everywhere they appear. Same stiffness `300` and zeta `0.9` in the only place they're defined. The test helper `_childTopLeft` is defined in Task 1 Step 1 and reused unchanged in Task 3 Step 1's new tests. ✓

**Risks / confirm during execution:**
- The hover-direction test depends on the pointer event sequencing of `addPointer(location: ...)` triggering `MouseRegion.onEnter` for the `SpringHoverButton`. If on this Flutter version it doesn't, an extra `await tester.pumpAndSettle()` after `addPointer` may be required before pumping the spring frames. The test's pump loop already provides headroom — if it fails on this point, the fix is `await tester.pump();` immediately after `addPointer`.
- The clamp magnitude assertions allow 0.5 px of slack (`4.5` / `3.5`) to absorb the small undershoot at zeta 0.9 within the pump window. If the assertion is too tight in practice, widen to `5.0` / `4.0` — but do NOT widen past the next-half-px or the test stops pinning the clamp.
