# Debug Probe — Local Opt-In

Production builds use `NoopDebugProbe` (defined in `debug_probe.dart`), which
has zero external dependencies. The real agent-wires probe is **not** a
committed dependency; it is wired locally by following the steps below.

## Why

`agent_wires_probe` lives outside this repo at
`../../../agent-wires/packages/agent_wires_probe`. Fresh clones would fail to
resolve the path if the sibling repo is absent, so we gate it behind a local
override that is gitignored.

---

## Steps to enable the real probe locally

1. **Clone `agent-wires` as a sibling repo** so the relative path resolves:

   ```
   ../../../agent-wires/packages/agent_wires_probe
   ```

   From the parent directory of `screenflow_studio`:

   ```sh
   git clone <agent-wires-repo-url> agent-wires
   ```

2. **Copy the template** to a gitignored concrete file:

   ```sh
   cp packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart.template \
      packages/screen_recorder/lib/debug/agent_wires_probe_binding.dart
   ```

3. **Add a dependency override** to
   `packages/screen_recorder/pubspec_overrides.yaml` (add under
   `dependency_overrides:`):

   ```yaml
   dependency_overrides:
     agent_wires_probe:
       path: ../../../agent-wires/packages/agent_wires_probe
   ```

   Then run `melos bootstrap` from the repo root to resolve the dependency:

   ```sh
   melos bootstrap
   ```

   > **WARNING — `pubspec_overrides.yaml` is git-TRACKED and melos-managed.**
   > Unlike `agent_wires_probe_binding.dart` and `main_dev.dart` (both
   > gitignored), this file is committed, and `melos bootstrap` rewrites it
   > (it manages the workspace path overrides). That means:
   >
   > - **Do NOT commit your local `agent_wires_probe` override.** It points at
   >   a sibling repo that does not exist on CI or other machines and would
   >   break their builds.
   > - After adding your override locally, tell git to ignore your changes to
   >   the file so you can't stage it by accident:
   >
   >   ```sh
   >   git update-index --skip-worktree packages/screen_recorder/pubspec_overrides.yaml
   >   ```
   >
   >   (Reverse later with `--no-skip-worktree`.) Alternatively, simply never
   >   stage `pubspec_overrides.yaml` when committing.

4. **Create a gitignored `lib/main_dev.dart`** that installs the real probe
   before delegating to the normal entry point:

   ```dart
   import 'package:screen_recorder/debug/agent_wires_probe_binding.dart';
   import 'package:screen_recorder/debug/debug_probe.dart';
   import 'package:screen_recorder/main.dart' as app;

   void main() {
     debugProbe = const AgentWiresDebugProbe();
     app.main();
   }
   ```

5. **Run with the dev entry point:**

   ```sh
   flutter run -t lib/main_dev.dart
   ```

---

## Files involved

| File | Description |
|------|-------------|
| `debug_probe.dart` | Committed seam: `DebugProbe` interface + `NoopDebugProbe` |
| `agent_wires_probe_binding.dart.template` | Committed template for the real binding |
| `agent_wires_probe_binding.dart` | **Gitignored** concrete file (copy from template) |
| `../main_dev.dart` | **Gitignored** dev entry point that sets `debugProbe` |
