# Federation Channel-Name Unification + Parity Docs Implementation Plan (Workstream D)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make every platform agree on the method/event channel names by routing all Dart sides through the shared `ScreenRecorderChannels`/`ScreenRecorderMethods` constants and fixing the Windows/Linux native literals; add the 3 missing method constants; and document macOS-first reality with a parity matrix (#6, #8).

**Architecture:** The platform interface already defines the canonical constants and exports them. Windows/Linux Dart currently hardcode `.../methods` (wrong token) and their native code hardcodes the stale `com.screenflow_studio.*` prefix — so those plugins can't talk to their own native side. Fix: Dart → constants; native literals → `com.slipreel.screen_recorder/recording` etc.

**Tech Stack:** Dart (platform interface + plugins), C++ (Windows), C (Linux), Markdown docs.

**Spec:** `docs/superpowers/specs/2026-05-26-critical-major-remediation-design.md` (Workstream D: #6, #8)

**Branch:** `remediation/critical-major`

## VERIFICATION CONSTRAINTS
- Dart changes (Tasks 1-2): verifiable via `flutter analyze` + the platform_interface test suite (+ a new constants-pin test). The Windows/Linux Dart packages' own tests throw `MissingPluginException` on a macOS host and are excluded from CI — `flutter analyze` is the gate for them.
- Native C++/C changes (Task 3): there is NO Windows/Linux toolchain here, so these are **string-literal edits verified by inspection only** (cannot compile-check). They are trivial (rename a channel prefix/token); flag as not-compile-verified.
- Docs (Task 4): prose.

## Ground truth (from recon)
- `screen_recorder_platform_interface/lib/src/constants.dart`: `ScreenRecorderChannels` (recording/frames/audio/cursor/micLevel, all `com.slipreel.screen_recorder/...`) + `ScreenRecorderMethods` (18 methods, lines 21-39). Exported via the barrel. MISSING from `ScreenRecorderMethods`: `isAccessibilityTrusted`, `requestAccessibilityPermission`, `getStockCursorImages` (declared in the interface abstract class, hardcoded as strings only in macOS Dart channel impl lines 103/111/118).
- macOS Dart (`screen_recorder_macos_method_channel.dart`) + macOS native (`ScreenRecorderMacosPlugin.swift`): already use the constants/correct literals. ✓
- Windows Dart (`screen_recorder_windows.dart:8-18`): hardcodes `com.slipreel.screen_recorder/methods` (method — wrong token), frames/cursor/audio `com.slipreel.../*`. Declares `_audioChannel` with NO native counterpart (Windows native has no audio channel).
- Linux Dart (`screen_recorder_linux.dart:8-18`): same hardcoded pattern (method `/methods`, frames/cursor/audio).
- Windows native (`screen_recorder_windows_plugin.cpp`): `com.screenflow_studio.screen_recorder/methods` (26), `/frames` (39), `/cursor` (66). No audio/micLevel.
- Linux native (`screen_recorder_linux_plugin.cc`): `com.screenflow_studio.screen_recorder/methods` (289), `/frames` (298), `/audio` (310), `/cursor` (322).
- Existing interface tests pin `listSources`/`captureThumbnail`/`selectRegion` constant VALUES (keep them). No test pins channel-name strings (net-new).
- Docs: platform_interface has NO README. `IMPLEMENTATION_PLAN.md:7,10` over-claim cross-platform. Windows README substantive; Linux README is a template stub.

---

## Task 1: Add the 3 missing method constants + route macOS Dart + pin test

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Create: `packages/screen_recorder_platform_interface/test/constants_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/constants_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('ScreenRecorderChannels', () {
    test('all channels use the com.slipreel.screen_recorder prefix', () {
      const prefix = 'com.slipreel.screen_recorder/';
      expect(ScreenRecorderChannels.recording, '${prefix}recording');
      expect(ScreenRecorderChannels.frames, '${prefix}frames');
      expect(ScreenRecorderChannels.audio, '${prefix}audio');
      expect(ScreenRecorderChannels.cursor, '${prefix}cursor');
      expect(ScreenRecorderChannels.micLevel, '${prefix}micLevel');
    });
  });

  group('ScreenRecorderMethods', () {
    test('includes the accessibility + stock-cursor methods', () {
      expect(ScreenRecorderMethods.isAccessibilityTrusted, 'isAccessibilityTrusted');
      expect(ScreenRecorderMethods.requestAccessibilityPermission,
          'requestAccessibilityPermission');
      expect(ScreenRecorderMethods.getStockCursorImages, 'getStockCursorImages');
    });
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/constants_test.dart`
Expected: FAIL — the 3 new method constants don't exist.

- [ ] **Step 3: Add the constants**

In `constants.dart`, append to `ScreenRecorderMethods` (after line 39, before the closing brace):
```dart
  static const String isAccessibilityTrusted = 'isAccessibilityTrusted';
  static const String requestAccessibilityPermission =
      'requestAccessibilityPermission';
  static const String getStockCursorImages = 'getStockCursorImages';
```

- [ ] **Step 4: Route the macOS Dart channel impl through them**

In `screen_recorder_macos_method_channel.dart`, replace the 3 hardcoded literals:
- line 103 `'isAccessibilityTrusted'` → `ScreenRecorderMethods.isAccessibilityTrusted`
- line 111 `'requestAccessibilityPermission'` → `ScreenRecorderMethods.requestAccessibilityPermission`
- line 118 `'getStockCursorImages'` → `ScreenRecorderMethods.getStockCursorImages`
(The constants are already in scope via the interface barrel import this file uses for `ScreenRecorderChannels`. Confirm the import exists; it does, since the file uses `ScreenRecorderChannels.recording`.)

- [ ] **Step 5: Run tests + analyze**

Run: `cd packages/screen_recorder_platform_interface && flutter test` (expect all pass incl. new + the existing listSources/captureThumbnail/selectRegion pins).
Run: `cd packages/screen_recorder_macos && flutter analyze --no-fatal-infos lib/screen_recorder_macos_method_channel.dart` (no errors; the 3 literals now resolve to constants).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/constants.dart packages/screen_recorder_platform_interface/test/constants_test.dart packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git commit -m "feat(interface): add accessibility/stock-cursor method constants; route macOS Dart through them"
```

---

## Task 2: Windows + Linux Dart → shared channel constants

**Files:**
- Modify: `packages/screen_recorder_windows/lib/screen_recorder_windows.dart`
- Modify: `packages/screen_recorder_linux/lib/screen_recorder_linux.dart`

- [ ] **Step 1: Windows Dart — use constants, drop the dead audio channel**

In `screen_recorder_windows.dart`:
- Ensure the interface is imported: `import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';` (add if missing).
- Replace the hardcoded channel constructions (lines 8-18):
```dart
  static const MethodChannel _channel =
      MethodChannel('com.slipreel.screen_recorder/methods');
  static const EventChannel _framesChannel =
      EventChannel('com.slipreel.screen_recorder/frames');
  static const EventChannel _cursorChannel =
      EventChannel('com.slipreel.screen_recorder/cursor');
  static const EventChannel _audioChannel =
      EventChannel('com.slipreel.screen_recorder/audio');
```
with (note: `const` → `final` because the constant references aren't compile-time const-composable as `const MethodChannel(...)` only if the arg is const — `ScreenRecorderChannels.recording` IS a `const String`, so `const MethodChannel(ScreenRecorderChannels.recording)` is valid; keep `const`):
```dart
  static const MethodChannel _channel =
      MethodChannel(ScreenRecorderChannels.recording);
  static const EventChannel _framesChannel =
      EventChannel(ScreenRecorderChannels.frames);
  static const EventChannel _cursorChannel =
      EventChannel(ScreenRecorderChannels.cursor);
```
DROP the `_audioChannel` field entirely (Windows native registers no audio channel — it's dead). Then remove any code that references `_audioChannel` (grep `_audioChannel` in the file; if it's only declared and never listened to, deletion is clean; if it's referenced, replace that usage with a clear "audio not supported on Windows" path or remove the dead listener).

- [ ] **Step 2: Linux Dart — use constants**

In `screen_recorder_linux.dart`: ensure the interface import exists; replace the 4 hardcoded channel literals (lines 8-18) with `ScreenRecorderChannels.recording` (method — fixes the `/methods` token), `ScreenRecorderChannels.frames`, `ScreenRecorderChannels.cursor`, `ScreenRecorderChannels.audio`. Linux native DOES register audio, so KEEP the audio channel here (just route through the constant).

- [ ] **Step 3: Analyze both packages**

Run: `cd packages/screen_recorder_windows && flutter analyze --no-fatal-infos` (no errors; no dangling `_audioChannel`).
Run: `cd packages/screen_recorder_linux && flutter analyze --no-fatal-infos` (no errors).
(Do NOT run their `flutter test` as a gate — those throw MissingPluginException on a macOS host; analyze is the gate.)

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_windows/lib/screen_recorder_windows.dart packages/screen_recorder_linux/lib/screen_recorder_linux.dart
git commit -m "fix(windows,linux): route Dart channels through shared constants (was .../methods)"
```

---

## Task 3: Windows + Linux native channel literals → com.slipreel

**Files:**
- Modify: `packages/screen_recorder_windows/windows/screen_recorder_windows_plugin.cpp`
- Modify: `packages/screen_recorder_linux/linux/screen_recorder_linux_plugin.cc`

**⚠️ Not compile-verified here (no Windows/Linux toolchain). These are literal string edits — verify by inspection + a grep that no `screenflow_studio` / `/methods` literal remains.**

- [ ] **Step 1: Windows native literals**

In `screen_recorder_windows_plugin.cpp`:
- line 26: `"com.screenflow_studio.screen_recorder/methods"` → `"com.slipreel.screen_recorder/recording"`
- line 39: `"com.screenflow_studio.screen_recorder/frames"` → `"com.slipreel.screen_recorder/frames"`
- line 66: `"com.screenflow_studio.screen_recorder/cursor"` → `"com.slipreel.screen_recorder/cursor"`

- [ ] **Step 2: Linux native literals**

In `screen_recorder_linux_plugin.cc`:
- line 289: `"com.screenflow_studio.screen_recorder/methods"` → `"com.slipreel.screen_recorder/recording"`
- line 298: `"com.screenflow_studio.screen_recorder/frames"` → `"com.slipreel.screen_recorder/frames"`
- line 310: `"com.screenflow_studio.screen_recorder/audio"` → `"com.slipreel.screen_recorder/audio"`
- line 322: `"com.screenflow_studio.screen_recorder/cursor"` → `"com.slipreel.screen_recorder/cursor"`

- [ ] **Step 3: Verify no stale literals remain**

Run: `grep -rn "screenflow_studio\|screen_recorder/methods" packages/screen_recorder_windows/windows packages/screen_recorder_linux/linux`
Expected: ZERO hits. (If the example apps under those packages reference `screenflow_studio` elsewhere, leave those — only the plugin channel registrations matter; report any other hits.)

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_windows/windows/screen_recorder_windows_plugin.cpp packages/screen_recorder_linux/linux/screen_recorder_linux_plugin.cc
git commit -m "fix(windows,linux): native channel names to com.slipreel/recording (match interface)"
```

---

## Task 4: Parity matrix + macOS-first docs

**Files:**
- Create: `packages/screen_recorder_platform_interface/README.md`
- Modify: `IMPLEMENTATION_PLAN.md` (lines 7, 10)
- Modify: `packages/screen_recorder_linux/README.md`

- [ ] **Step 1: Create the interface README with a parity matrix**

```markdown
<!-- packages/screen_recorder_platform_interface/README.md -->
# screen_recorder_platform_interface

The common platform interface for the `screen_recorder` federated plugin.
All channel + method names are defined in `lib/src/constants.dart`
(`ScreenRecorderChannels`, `ScreenRecorderMethods`) — every platform
implementation MUST construct its channels from these constants so the Dart
and native sides agree.

## Platform status

**macOS is the only fully-implemented, shipping platform.** Windows and Linux
are early placeholders: they implement a subset of discovery/control methods
and are NOT integrated into the Slipreel app (the app depends only on
`screen_recorder_macos`).

| Feature | macOS | Windows | Linux |
|---|:---:|:---:|:---:|
| getAvailableScreens / getAvailableWindows | ✅ | ✅ | ✅ |
| getAudioDevices | ✅ | ◻️ (todo) | ◻️ (todo) |
| startLiveRecording / stopLiveRecording | ✅ | ❌ | ❌ |
| listSources / captureThumbnail | ✅ | ❌ | ❌ |
| selectRegion / pickSource | ✅ | ❌ | ❌ |
| microphone + system-audio capture | ✅ | ❌ | ❌ |
| cursor state + stock cursor images | ✅ | ◻️ (position only) | ◻️ (position only) |
| permissions / accessibility | ✅ | ◻️ | ◻️ |

Legend: ✅ implemented · ◻️ partial/stub · ❌ not implemented.

Windows registers method + frames + cursor channels (no audio); Linux registers
method + frames + audio + cursor. Only macOS registers the micLevel channel.
```

- [ ] **Step 2: Soften IMPLEMENTATION_PLAN.md cross-platform claims**

In `IMPLEMENTATION_PLAN.md`:
- line 7 `**Target Platforms**: macOS, Windows, Linux (starting with macOS)` → `**Target Platforms**: macOS (shipping). Windows & Linux are early placeholders, not integrated into the app — see screen_recorder_platform_interface/README.md for the parity matrix.`
- line 10: change `Build a cross-platform screen recording tool (macOS, Windows, Linux) ... Target all 6 core features for a production-ready MVP.` → `Build a macOS-first screen recording tool using Flutter for UI and a federated native plugin for screen capture (Windows/Linux scaffolding exists but is not wired into the app). Target all 6 core features for a production-ready macOS MVP.`
(Match the surrounding markdown style; keep the rest of the file intact.)

- [ ] **Step 3: Replace the Linux README stub**

`packages/screen_recorder_linux/README.md` is the default Flutter template. Replace with a short, accurate status:
```markdown
# screen_recorder_linux

Linux implementation of the `screen_recorder` federated plugin (X11 + PipeWire
capture). **Early placeholder — not integrated into the Slipreel app and not
feature-complete.** See `screen_recorder_platform_interface/README.md` for the
cross-platform parity matrix. Channel names come from `ScreenRecorderChannels`.
```

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_platform_interface/README.md IMPLEMENTATION_PLAN.md packages/screen_recorder_linux/README.md
git commit -m "docs: parity matrix + macOS-first framing for the federated plugin"
```

---

## Self-Review

**Spec coverage (D):**
- #6 channel-name unification → Task 1 (interface method constants + macOS Dart) + Task 2 (Windows/Linux Dart → constants) + Task 3 (Windows/Linux native literals). After this, ALL layers use `com.slipreel.screen_recorder/recording` + the shared event-channel names. ✓
- #8 parity docs → Task 4 (interface README matrix + IMPLEMENTATION_PLAN macOS-first + Linux README). ✓

**Placeholder scan:** No placeholders. Native edits (Task 3) are exact literal replacements at named lines.

**Type consistency:** `ScreenRecorderChannels.{recording,frames,audio,cursor}` and `ScreenRecorderMethods.{isAccessibilityTrusted,requestAccessibilityPermission,getStockCursorImages}` used consistently across Tasks 1-2. Native literals (Task 3) match `ScreenRecorderChannels` values exactly.

**Risks / confirm during execution:**
- `const MethodChannel(ScreenRecorderChannels.recording)` requires the constant to be a `const String` — it is (`static const String`), so the `const` channel construction stays valid. If the analyzer complains, switch those fields to `final`.
- Windows `_audioChannel` removal: grep for all its usages first; if it's listened-to somewhere, remove that dead listener cleanly (don't leave a reference).
- Task 3 native edits are NOT compile-verified (no Win/Linux toolchain) — they're trivial string swaps; the grep in Step 3 is the guard. Flag as inspection-only.
- Keep the existing pinned constant values (`listSources`/`captureThumbnail`/`selectRegion`) unchanged — only ADD constants.
