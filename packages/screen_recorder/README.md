# screen_recorder

The main Flutter application package for **Slipreel** (`com.slipreel.app`) — a macOS-first
Flutter desktop screen recorder and non-linear editor.

## Running the app

```bash
flutter run -d macos
```

Requires Flutter 3.41.5+. Full specs live under `docs/superpowers/specs/`.

## Workspace bootstrap

This repo uses [Melos](https://melos.invertase.dev/) to manage the multi-package workspace.
From the repo root:

```bash
melos bootstrap
```

## Architecture

| Package | Role |
|---|---|
| `packages/screen_recorder` | Flutter UI (this package) |
| `packages/slipreel_engine` | Rendering and export engine (FFmpeg pipeline) |
| `packages/screen_recorder_macos` | Native macOS plugin (ScreenCaptureKit, VideoToolbox) |
| `packages/screen_recorder_platform_interface` | Federated plugin contract |

Platform parity matrix: see
[`packages/screen_recorder_platform_interface/README.md`](../screen_recorder_platform_interface/README.md).
