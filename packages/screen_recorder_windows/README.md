# screen_recorder_windows

Windows implementation of the screen_recorder plugin using Graphics Capture API.

## Features

- Window capture using Graphics Capture API
- Display/screen capture
- Frame streaming with BGRA format
- Real-time frame capture at configurable FPS
- Windows 10 1803+ support

## Requirements

- Windows 10 version 1803 (Build 17134) or later
- Graphics Capture API support
- Visual Studio 2019 or later with C++ Desktop development

## Architecture

This plugin uses Windows Graphics Capture API (WinRT/C++) to capture screen content:

- **GraphicsCaptureManager**: Core capture functionality
  - Window and display enumeration via Win32 API
  - Capture session management
  - D3D11 texture to BGRA conversion
  - Frame streaming to Flutter

- **ScreenRecorderWindowsPlugin**: Flutter platform interface
  - Method channel for control operations
  - Event channel for frame streaming
  - Permission handling

## Testing on Windows

To test this plugin on a Windows machine:

```bash
cd packages/screen_recorder_windows
flutter test
```

To run the example app:

```bash
cd packages/screen_recorder_windows/example
flutter run -d windows
```

## Implementation Notes

- Uses C++/WinRT for modern Windows API access
- Requires C++17 or later
- Frame format is standardized to BGRA for cross-platform compatibility
- Graphics Capture API provides hardware-accelerated capture
- D3D11 is used for texture access and conversion

## Limitations

- Windows 10 1803+ required (older versions not supported)
- Permission is granted when user selects capture source
- No pre-check permission mechanism available
- Cursor tracking requires separate implementation (see cursor_tracker.cpp)

## License

See main project LICENSE file.

