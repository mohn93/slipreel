# Integration Tests

This directory contains integration tests that verify cross-platform behavior and feature parity across macOS, Windows, and Linux implementations.

## Important Note

These integration tests **cannot be run directly** via `flutter test` because they require a platform plugin implementation to be registered. When run via `flutter test`, all tests will be skipped.

## How to Run Integration Tests

### Option 1: Run from Platform Plugin Example Apps

Each platform plugin has an example app where you can run integration tests:

#### macOS
```bash
cd packages/screen_recorder_macos/example
flutter test integration_test/
```

#### Windows
```bash
cd packages/screen_recorder_windows/example
flutter test integration_test/
```

#### Linux
```bash
cd packages/screen_recorder_linux/example
flutter test integration_test/
```

### Option 2: Run in a Real Flutter App

1. Create a Flutter app that depends on `screen_recorder`
2. Copy the test files to your app's `integration_test/` directory
3. Run integration tests:
   ```bash
   flutter test integration_test/
   ```

### Option 3: Use CI/CD

The GitHub Actions workflow (`.github/workflows/test-all-platforms.yml`) automatically runs tests on all three platforms.

## Test Files

### `cross_platform_test.dart`
Verifies that all platform implementations provide:
- Consistent API surface
- Compatible data structures (FrameData, CursorPosition, etc.)
- Proper error handling
- Expected feature support

Key tests:
- Platform registration
- Window enumeration
- Screen enumeration
- Frame streaming
- Cursor tracking
- Recording lifecycle (start/stop)
- Error handling

### `cursor_rendering_test.dart`
Tests cursor tracking functionality across platforms:
- Cursor stream availability
- Position tracking
- Click detection
- Timestamp accuracy

## Platform-Specific Behavior

Tests are aware of platform differences and adjust expectations accordingly:

### macOS
- Expects detailed window metadata (owner name, title)
- Tests ScreenCaptureKit integration
- Verifies permission handling

### Windows
- Expects Graphics Capture API behavior
- Tests window enumeration
- Verifies consent picker integration

### Linux
- Tests both PipeWire (Wayland) and X11 modes
- Knows that window enumeration may be empty on PipeWire
- Knows that cursor tracking is unavailable on Wayland

## Running All Tests

To run all unit tests (excluding integration tests):
```bash
cd packages/screen_recorder
flutter test --exclude-tags=integration
```

To run only integration tests (they will skip unless platform is registered):
```bash
cd packages/screen_recorder
flutter test test/integration/
```

## Writing New Integration Tests

When adding new integration tests:

1. Check if platform is available at the start:
   ```dart
   bool platformAvailable = false;
   try {
     ScreenRecorderPlatform.instance;
     platformAvailable = true;
   } catch (e) {
     // Platform not registered
   }
   ```

2. Skip tests gracefully if platform isn't available:
   ```dart
   test('my test', () {
     if (!platformAvailable) {
       markTestSkipped('Platform implementation not registered.');
       return;
     }
     // ... test code
   });
   ```

3. Account for platform differences:
   ```dart
   if (Platform.isMacOS) {
     // macOS-specific assertions
   } else if (Platform.isWindows) {
     // Windows-specific assertions
   }
   ```

4. Handle features that may not be available on all platforms:
   ```dart
   // Linux/Wayland may not have window enumeration
   if (Platform.isLinux) {
     // Don't assert windows.isNotEmpty
   }
   ```

## Debugging Integration Tests

### Test Fails on CI but Passes Locally
- Check platform differences (macOS vs Windows vs Linux)
- Verify CI environment has necessary permissions
- Check if display/window sources are available in CI

### Test Hangs
- Verify you're properly cleaning up streams and subscriptions
- Check for deadlocks in platform code
- Ensure recording is properly stopped

### Platform Not Registered Error
- Make sure you're running from a context where the platform plugin is registered
- Check that the plugin's `registerWith()` method has been called
- Verify dependencies in `pubspec.yaml`

## See Also

- [PLATFORM_NOTES.md](../../PLATFORM_NOTES.md) - Platform-specific behavior and limitations
- [.github/workflows/test-all-platforms.yml](../../../../.github/workflows/test-all-platforms.yml) - CI/CD configuration
