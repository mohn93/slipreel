# Platform-Specific Behavior

This document describes platform-specific behavior, differences, and limitations of the ScreenFlow Studio screen recording functionality.

## macOS

### Technology Stack
- Uses **ScreenCaptureKit** (requires macOS 12.3+)
- Native Swift implementation with Objective-C++ bridge
- Hardware-accelerated video encoding via VideoToolbox

### Capabilities
- Full window enumeration with detailed metadata (owner, title)
- Display capture with per-display selection
- System audio capture via AVFoundation
- Cursor tracking via NSEvent monitoring
- Screen recording permission via TCC (Transparency, Consent, and Control)

### Limitations
- Requires explicit screen recording permission from user
- Permission must be granted in System Preferences > Security & Privacy
- Cannot capture desktop wallpaper or system UI in some cases
- Hardware encoding only available on macOS 13+

### Testing Notes
- First run will trigger permission dialog
- Permission persists across app launches
- Test on both Intel and Apple Silicon Macs if possible

---

## Windows

### Technology Stack
- Uses **Windows.Graphics.Capture API** (requires Windows 10 1803+, Build 17134)
- Native C++ implementation with COM/WinRT
- Direct3D 11 for frame capture
- Low-level mouse hook for cursor tracking

### Capabilities
- Window enumeration via EnumWindows
- Display capture with monitor selection
- Cursor tracking via SetWindowsHookEx
- User consent via system picker on first capture

### Limitations
- Requires Windows 10 version 1803 (April 2018 Update) or later
- Graphics Capture API requires DirectX 11 capable GPU
- First capture requires user to select window/screen via system picker
- Some windows may be excluded (admin/secure windows)
- Hardware encoding support varies by GPU vendor

### Testing Notes
- Test on both Windows 10 and Windows 11
- Verify on different GPU vendors (NVIDIA, AMD, Intel)
- First run triggers consent picker
- Consent persists for app instance

---

## Linux

### Technology Stack
- **PipeWire** for Wayland compositors (requires PipeWire 0.3+)
- **X11** fallback for X.org display server
- Native C++ implementation with GLib/GObject integration
- X11 cursor tracking via XQueryPointer

### Wayland (PipeWire)

#### Capabilities
- Display capture via xdg-desktop-portal
- Screen selection via system picker
- Audio capture support
- Secure and sandboxed

#### Limitations
- **Window enumeration not available** (security restriction)
- **Cursor tracking not available** (portal limitation)
- Requires xdg-desktop-portal and compatible portal backend
- System picker required for every session
- Window capture uses same system picker as display

### X11

#### Capabilities
- Full window enumeration with window tree
- Direct window and display capture
- Cursor tracking via XQueryPointer
- No permission dialogs

#### Limitations
- No sandboxing (direct X11 access)
- May not work on Wayland-only systems
- Cursor appearance may not match theme
- Some compositors hide windows from XQueryPointer

### Testing Notes
- Test on both Wayland and X11 sessions
- Verify with different desktop environments (GNOME, KDE, etc.)
- Check PipeWire version: `pipewire --version`
- Ensure xdg-desktop-portal is running: `systemctl --user status xdg-desktop-portal`

---

## Feature Parity Matrix

| Feature | macOS | Windows | Linux (PipeWire) | Linux (X11) |
|---------|-------|---------|------------------|-------------|
| Window capture | ✅ Full | ✅ Full | ⚠️ System picker only | ✅ Full |
| Display capture | ✅ Full | ✅ Full | ✅ Full | ✅ Full |
| Window enumeration | ✅ Full | ✅ Full | ❌ Not available | ✅ Full |
| Cursor tracking | ✅ Full | ✅ Full | ❌ Not available | ✅ Full |
| Audio capture | ✅ System + mic | ✅ System + mic | ✅ System + mic | ✅ System + mic |
| Hardware encoding | ✅ VideoToolbox | ⚠️ Vendor-dependent | ❌ Software only | ❌ Software only |
| Permission system | ✅ TCC | ⚠️ First-run consent | ✅ Portal | ❌ None |

### Legend
- ✅ **Full support** - Feature fully implemented and tested
- ⚠️ **Partial support** - Feature available with limitations
- ❌ **Not supported** - Feature not available on this platform

---

## Performance Characteristics

### macOS
- **Frame capture**: ~5-10ms per frame (hardware accelerated)
- **Encoding**: Hardware VideoToolbox encoding available
- **Memory**: Efficient with shared memory buffers
- **CPU**: Low CPU usage with hardware encoding

### Windows
- **Frame capture**: ~8-15ms per frame (DirectX 11)
- **Encoding**: Vendor-dependent hardware encoding (varies)
- **Memory**: Moderate usage with DirectX surface copies
- **CPU**: Medium CPU usage, varies by GPU

### Linux (PipeWire)
- **Frame capture**: ~10-20ms per frame (depends on compositor)
- **Encoding**: Software encoding only (x264/x265)
- **Memory**: Efficient with DMA-BUF when supported
- **CPU**: High CPU usage for encoding

### Linux (X11)
- **Frame capture**: ~5-15ms per frame (direct X11 capture)
- **Encoding**: Software encoding only (x264/x265)
- **Memory**: Higher usage (copy-based capture)
- **CPU**: High CPU usage for encoding

---

## Common Issues and Solutions

### macOS

**Issue**: Permission denied error
- **Solution**: Grant screen recording permission in System Preferences > Security & Privacy > Screen Recording
- **Note**: App must be restarted after granting permission

**Issue**: Cannot capture certain windows
- **Solution**: Some system windows (e.g., login screen) cannot be captured for security reasons

### Windows

**Issue**: Graphics Capture API not available
- **Solution**: Ensure Windows 10 version 1803 or later. Check: `winver`
- **Note**: Update Windows if version is too old

**Issue**: Black screen in capture
- **Solution**: Update graphics drivers. DirectX 11 compatibility required.

### Linux (PipeWire)

**Issue**: No sources available
- **Solution**: Ensure xdg-desktop-portal is installed and running
- **Check**: `systemctl --user status xdg-desktop-portal`

**Issue**: PipeWire not found
- **Solution**: Install PipeWire 0.3 or later: `sudo apt install pipewire libpipewire-0.3-dev`

### Linux (X11)

**Issue**: Cannot capture window
- **Solution**: Ensure DISPLAY environment variable is set
- **Check**: `echo $DISPLAY` (should show :0 or similar)

**Issue**: Cursor not visible
- **Solution**: X11 cursor tracking may fail on some compositors. This is a known limitation.

---

## Development Notes

### Building for Each Platform

#### macOS
```bash
cd packages/screen_recorder_macos
flutter pub get
flutter build macos
```

#### Windows
```bash
cd packages/screen_recorder_windows
flutter pub get
flutter build windows
```

#### Linux
```bash
cd packages/screen_recorder_linux
flutter pub get
# Install dependencies first
sudo apt-get install libpipewire-0.3-dev libx11-dev
flutter build linux
```

### Running Tests

All platforms support the same test suite:

```bash
cd packages/screen_recorder
flutter test
```

Platform-specific integration tests will automatically detect the current platform and adjust expectations accordingly.

---

## Future Enhancements

Potential improvements not currently implemented:

### All Platforms
- Hardware-accelerated encoding on Linux
- Multiple monitor region selection
- Custom cursor images/themes
- Audio mixing and effects

### Windows
- MediaFoundation hardware encoding
- Game bar integration
- HDR capture support

### Linux
- Wayland cursor tracking (waiting for portal support)
- Direct DMA-BUF capture (zero-copy)
- VA-API hardware encoding

### Mobile
- ChromeOS support via Android plugin
- iOS/iPadOS support with ReplayKit

---

## Testing Checklist

When testing on a new platform or after changes, verify:

- [ ] App launches without errors
- [ ] Window/screen list populates correctly
- [ ] Recording starts without errors
- [ ] Frames are captured at expected rate
- [ ] Cursor movements are tracked (where supported)
- [ ] Recording stops cleanly
- [ ] Output file is valid and playable
- [ ] Multiple recordings work in sequence
- [ ] Permission dialogs appear as expected
- [ ] Audio is captured correctly (if enabled)
- [ ] Memory usage is reasonable
- [ ] CPU usage is acceptable
- [ ] No memory leaks after multiple recordings

---

## Support Matrix

### Minimum Requirements

| Platform | Minimum Version | Recommended |
|----------|----------------|-------------|
| macOS | 12.3 (Monterey) | 13.0+ (Ventura) |
| Windows | 10 Build 17134 (1803) | 11 22H2 |
| Linux | PipeWire 0.3+ or X11 | PipeWire 0.3.50+ |

### Tested Configurations

**macOS**
- macOS 12.3 Monterey (Intel)
- macOS 13.0 Ventura (Apple Silicon)
- macOS 14.0 Sonoma (Apple Silicon)

**Windows**
- Windows 10 21H2 (Build 19044)
- Windows 11 22H2 (Build 22621)

**Linux**
- Ubuntu 22.04 LTS (Wayland/GNOME)
- Ubuntu 22.04 LTS (X11/GNOME)
- Fedora 38 (Wayland/GNOME)
- Arch Linux (Wayland/KDE)

---

## Contact and Support

For platform-specific issues:
- Check the GitHub issues page
- Include platform, version, and error messages
- Attach logs from debug builds if possible
- Describe exact steps to reproduce

For contributing platform support:
- Review existing platform implementations
- Follow the platform interface contract
- Add comprehensive tests
- Update this documentation
