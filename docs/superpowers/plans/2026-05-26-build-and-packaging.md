# Build & Packaging Implementation Plan (Workstream B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the monorepo build on a fresh clone with no external repo, and make CI actually analyze and test every package on a compatible toolchain.

**Architecture:** Replace the hard `agent_wires_probe` path dependency with a no-op `DebugProbe` seam in the app (real probe wired only via a local, gitignored binding + dependency override). Rewrite the GitHub workflow to run `melos bootstrap → analyze → test` across all packages on a Flutter that ships Dart ≥ 3.9.

**Tech Stack:** Flutter/Dart, Melos, GitHub Actions, `dart:developer` VM-service extensions.

**Spec:** `docs/superpowers/specs/2026-05-26-critical-major-remediation-design.md` (Workstream B; Critical #4, #5)

**Branch:** `remediation/critical-major` (already checked out)

---

## File Structure

- Create `packages/screen_recorder/lib/debug/debug_probe.dart` — `DebugProbe` interface + `NoopDebugProbe` default + mutable `debugProbe` global. The single seam the app talks to.
- Create `packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart.template` — committed template of the real probe binding (NOT compiled; `.template` so it has no effect on `pub get`/analyze).
- Create `packages/screen_recorder/lib/debug/README.md` — local opt-in instructions + the `pubspec_overrides.yaml` snippet.
- Modify `packages/screen_recorder/lib/main.dart` — drop the `agent_wires_probe` import + direct calls; route through `debugProbe`.
- Modify `packages/screen_recorder/pubspec.yaml` — remove the `agent_wires_probe` dependency.
- Modify `.gitignore` (root) — ignore the local binding + dev entrypoint + local override.
- Create `packages/screen_recorder/test/debug/debug_probe_test.dart` — defaults are no-op.
- Create `packages/screen_recorder/test/architecture/no_agent_wires_import_test.dart` — production `lib/` never imports `agent_wires_probe`.
- Modify `.github/workflows/test-all-platforms.yml` — melos-based analyze + test.

---

## Task 1: DebugProbe seam with no-op default

**Files:**
- Create: `packages/screen_recorder/lib/debug/debug_probe.dart`
- Test: `packages/screen_recorder/test/debug/debug_probe_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/debug/debug_probe_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/debug/debug_probe.dart';

void main() {
  group('DebugProbe', () {
    test('default global is a NoopDebugProbe', () {
      expect(debugProbe, isA<NoopDebugProbe>());
    });

    test('NoopDebugProbe.install() does nothing and does not throw', () {
      const NoopDebugProbe().install();
    });

    test('NoopDebugProbe.navigatorObserver() returns null', () {
      expect(const NoopDebugProbe().navigatorObserver(), isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/debug/debug_probe_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:screen_recorder/debug/debug_probe.dart'`.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/debug/debug_probe.dart
import 'package:flutter/widgets.dart';

/// Seam for optional, debug-only runtime instrumentation.
///
/// Production code talks only to this interface, so the app compiles and
/// runs with no external probe package present. To wire the real
/// agent-wires probe locally, see `lib/debug/README.md`.
abstract class DebugProbe {
  /// Installs runtime introspection hooks (VM-service extensions, etc.).
  void install();

  /// Optional navigator observer for route tracking. Null when disabled.
  NavigatorObserver? navigatorObserver();
}

/// Default no-op probe used in all committed builds.
class NoopDebugProbe implements DebugProbe {
  const NoopDebugProbe();

  @override
  void install() {}

  @override
  NavigatorObserver? navigatorObserver() => null;
}

/// Mutable global the app reads. Override before `main()` runs (e.g. from a
/// local `main_dev.dart`) to install a real probe.
DebugProbe debugProbe = const NoopDebugProbe();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/debug/debug_probe_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/debug/debug_probe.dart packages/screen_recorder/test/debug/debug_probe_test.dart
git commit -m "feat(app): add DebugProbe seam with no-op default"
```

---

## Task 2: Route main.dart through the seam (remove direct probe use)

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart` (lines 4, 36-42, 168-171)

- [ ] **Step 1: Remove the agent_wires import, add the seam import**

In `packages/screen_recorder/lib/main.dart`, delete line 4:

```dart
import 'package:agent_wires_probe/agent_wires_probe.dart';
```

Add (alongside the other relative imports near line 19):

```dart
import 'debug/debug_probe.dart';
```

- [ ] **Step 2: Replace the install call**

Replace the block at lines 36-42:

```dart
  if (kDebugMode || kProfileMode) {
    AgentWiresProbe.install();
    _registerSlipreelDebugExtensions();
    AppLogger.platform.i(
      'AgentWiresProbe installed (ext.qa.* + ext.slipreel.* registered)',
    );
  }
```

with:

```dart
  if (kDebugMode || kProfileMode) {
    debugProbe.install();
    _registerSlipreelDebugExtensions();
    AppLogger.platform.i(
      'Debug probe installed (ext.slipreel.* registered)',
    );
  }
```

(`_registerSlipreelDebugExtensions()` stays — it uses only `dart:developer`, no probe.)

- [ ] **Step 3: Replace the navigator observer**

Replace the `MyApp.build` navigatorObservers (lines 168-171):

```dart
      navigatorObservers: [
        if (kDebugMode || kProfileMode)
          AgentWiresProbe.routeTracker.createObserver(),
      ],
```

with (compute once so we don't build two observers):

```dart
      navigatorObservers: [
        if (debugProbe.navigatorObserver() case final observer?) observer,
      ],
```

- [ ] **Step 4: Verify the app still analyzes (import removed, references gone)**

Run: `cd packages/screen_recorder && flutter analyze lib/main.dart`
Expected: No errors referencing `AgentWiresProbe` or `agent_wires_probe`. (Analyzer still resolves because the dependency is present until Task 4; that's fine — we only removed the *references*.)

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "refactor(app): route debug probe through DebugProbe seam"
```

---

## Task 3: Guard test — production lib never imports agent_wires_probe

**Files:**
- Create: `packages/screen_recorder/test/architecture/no_agent_wires_import_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/architecture/no_agent_wires_import_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no committed lib/ source imports agent_wires_probe', () {
    final libDir = Directory('lib');
    final offenders = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue; // skips .template
      final text = entity.readAsStringSync();
      if (text.contains('package:agent_wires_probe')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'agent_wires_probe must stay optional; found imports in: '
          '$offenders',
    );
  });
}
```

- [ ] **Step 2: Run test to verify it passes (Task 2 already removed the import)**

Run: `cd packages/screen_recorder && flutter test test/architecture/no_agent_wires_import_test.dart`
Expected: PASS. (If it fails, an import was missed in Task 2 — fix it.)

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/test/architecture/no_agent_wires_import_test.dart
git commit -m "test(app): guard against agent_wires_probe imports in lib"
```

---

## Task 4: Remove the dependency + add local opt-in template & docs

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml` (lines 74-84)
- Create: `packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart.template`
- Create: `packages/screen_recorder/lib/debug/README.md`
- Modify: `.gitignore` (root)

- [ ] **Step 1: Remove the dependency block from pubspec.yaml**

Delete lines 74-84 (the comment block plus the dependency):

```yaml
  # In-process runtime probe that exposes the widget tree, captured
  # debugPrint output, and synthesised gestures to an LLM agent via the
  # Dart VM service. Paired with the `agent_wires_mcp` MCP server (a
  # global Dart CLI) which bridges those VM-service extensions onto
  # tools the agent can call. Path-depended on the local source so we
  # can extend it with project-specific service extensions
  # (`ext.slipreel.*`) as the debugging needs grow. The runtime call
  # to `AgentWiresProbe.install()` is gated by `kDebugMode || kProfileMode`
  # so it is a no-op in release builds.
  agent_wires_probe:
    path: ../../../agent-wires/packages/agent_wires_probe
```

Leave `lucide_icons_flutter: ^3.1.14+2` in place.

- [ ] **Step 2: Create the binding template**

```dart
// packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart.template
//
// LOCAL DEV ONLY — see README.md in this folder.
// Copy this file to `agent_wires_probe_binding.dart` (gitignored) and add the
// dependency override described in the README to wire the real probe.
import 'package:agent_wires_probe/agent_wires_probe.dart';
import 'package:flutter/widgets.dart';

import 'debug_probe.dart';

/// Real probe binding backed by the agent-wires package.
class AgentWiresDebugProbe implements DebugProbe {
  const AgentWiresDebugProbe();

  @override
  void install() => AgentWiresProbe.install();

  @override
  NavigatorObserver? navigatorObserver() =>
      AgentWiresProbe.routeTracker.createObserver();
}
```

- [ ] **Step 3: Create the local-dev README**

````markdown
<!-- packages/screen_recorder/lib/debug/README.md -->
# Debug probe (optional, local-only)

Production builds use `NoopDebugProbe` — no external dependency required.

To wire the agent-wires runtime probe on your machine:

1. Clone `agent-wires` as a sibling of this repo so the path
   `../../../agent-wires/packages/agent_wires_probe` resolves.
2. Copy the template into place (this copy is gitignored):
   ```bash
   cp lib/debug/agent_wires_probe_binding.dart.template \
      lib/debug/agent_wires_probe_binding.dart
   ```
3. Add a local dependency override. Create
   `packages/screen_recorder/pubspec_overrides.local.yaml` is NOT read by pub;
   instead add to your local (gitignored) `pubspec_overrides.yaml`:
   ```yaml
   dependency_overrides:
     agent_wires_probe:
       path: ../../../agent-wires/packages/agent_wires_probe
   ```
   (Melos manages `pubspec_overrides.yaml`; after editing, run
   `melos bootstrap` from the repo root.)
4. Create a local dev entrypoint `lib/main_dev.dart` (gitignored):
   ```dart
   import 'debug/agent_wires_probe_binding.dart';
   import 'debug/debug_probe.dart';
   import 'main.dart' as app;

   Future<void> main() async {
     debugProbe = const AgentWiresDebugProbe();
     await app.main();
   }
   ```
5. Run with `flutter run -t lib/main_dev.dart`.
````

- [ ] **Step 4: Gitignore the local files**

Append to the root `.gitignore`:

```gitignore
# Local-only debug probe wiring (see packages/screen_recorder/lib/debug/README.md)
packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart
packages/screen_recorder/lib/main_dev.dart
```

- [ ] **Step 5: Re-bootstrap and verify a clean resolve**

Run from repo root: `dart pub global activate melos && melos bootstrap`
Expected: bootstrap succeeds; `packages/screen_recorder/pubspec_overrides.yaml` (melos-generated) no longer references `agent_wires_probe`. If that file is tracked and still lists it, the bootstrap regenerated it — stage the change.

- [ ] **Step 6: Verify analyze + test are green without the external repo**

Run: `cd packages/screen_recorder && flutter analyze`
Expected: no errors (no unresolved `agent_wires_probe`).
Run: `cd packages/screen_recorder && flutter test test/debug/debug_probe_test.dart test/architecture/no_agent_wires_import_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/pubspec.yaml \
        packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart.template \
        packages/screen_recorder/lib/debug/README.md \
        .gitignore
# stage the regenerated overrides only if it is a tracked file:
git add packages/screen_recorder/pubspec_overrides.yaml 2>/dev/null || true
git commit -m "build(app): make agent_wires_probe an optional local-only dependency"
```

---

## Task 5: Rewrite the CI workflow to melos analyze + test

**Files:**
- Modify: `.github/workflows/test-all-platforms.yml` (full rewrite)

- [ ] **Step 1: Replace the workflow file contents**

```yaml
# .github/workflows/test-all-platforms.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  analyze-and-test:
    name: Analyze + Test (macOS)
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: dart pub global activate melos
      - run: melos bootstrap
      - run: melos analyze
      - run: melos test

  test-linux:
    name: Test (Linux)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: |
          sudo apt-get update
          sudo apt-get install -y libpipewire-0.3-dev libx11-dev
      - run: dart pub global activate melos
      - run: melos bootstrap
      - run: melos test
```

Rationale (do not include in the file): `channel: stable` guarantees a Dart ≥ 3.9.2 to satisfy `sdk: ^3.9.2` (the old pin `3.16.0` shipped Dart 3.2 and could never resolve). `melos analyze`/`melos test` fan out across all six packages — the engine (65 tests) and platform interface (11 tests) were previously never run. The Windows job is dropped for now (macOS-first; Dart tests are platform-independent and covered by the macOS + Linux jobs); native build verification is a future workstream.

- [ ] **Step 2: Validate the workflow YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/test-all-platforms.yml')); print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 3: Sanity-run the CI commands locally as a proxy**

Run from repo root: `melos analyze`
Expected: analyzer completes; pre-existing warnings (from deferred Minors) are acceptable, but there must be **no new errors** introduced by Workstream B. If `melos analyze` treats infos/warnings as failures and the baseline is already noisy, note the baseline; do not fix Minors here.
Run from repo root: `melos test`
Expected: all package test suites run; the screen_recorder, slipreel_engine, and platform_interface suites execute. Record any pre-existing failures unrelated to this workstream (do not fix here; report them).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test-all-platforms.yml
git commit -m "ci: run melos analyze + test across all packages on stable Flutter"
```

---

## Self-Review

**Spec coverage (Workstream B):**
- B1 agent_wires dev-only → Tasks 1–4 (seam, main.dart rewrite, guard test, dep removal + local opt-in). ✓
- B2 CI rewrite (melos analyze+test, Dart ≥ 3.9, checkout@v4) → Task 5. ✓
- Success criterion "fresh clone runs melos bootstrap + analyze + test green" → Task 4 Step 5–6 + Task 5 Step 3. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases". All code shown in full. ✓

**Type consistency:** `DebugProbe` interface (`install()`, `navigatorObserver()`) and `debugProbe` global are used identically in Task 1 (definition), Task 2 (`debugProbe.install()`, `debugProbe.navigatorObserver()`), and Task 4 template (`AgentWiresDebugProbe implements DebugProbe`). ✓

**Known assumptions to confirm during execution:**
- Whether `packages/screen_recorder/pubspec_overrides.yaml` is git-tracked (Task 4 Step 5/7 handles both cases).
- Baseline `melos analyze`/`melos test` noise from deferred Minors (Task 5 Step 3 records, does not fix).
