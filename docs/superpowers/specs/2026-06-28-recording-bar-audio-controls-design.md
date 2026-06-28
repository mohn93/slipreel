# Recording bar: simplify audio-source controls (issue #11)

## Problem

The recording bar swaps its **system-audio** control for a **device-audio** toggle
whenever the armed source is an external device (iPhone/iPad):

```dart
// recording_bar.dart
if (deviceMode)
  _DeviceAudioControl(...)
else
  _SystemAudioControl(...)
```

`deviceMode` is derived from `selectedSourceKind == RecordingSource.device`
(`recording_bar_screen.dart`). Because `selectedSourceKind` reflects the **last
recording** and is never reset, the bar stays locked in device mode after a phone
recording. Tapping Display/Window/Area immediately *starts* a recording, so there
is no way to get the normal audio controls back without committing to a screen
recording — the bar feels "stuck on phone selectors."

Secondary issues:
- The `_DeviceAudioControl` toggle has no chevron and doesn't read as interactive,
  so it feels locked.
- It's unclear which audio is captured for which recording type.

## Decision

Remove the device-mode bar swap entirely. The bar is a **configuration surface for
screen recordings**: it always shows the same controls (mic + system audio),
regardless of what was last recorded. Device audio is handled **automatically** at
device-record time — a device recording always captures its own audio plus the
selected mic. There is no device-audio toggle in the UI.

This makes the bar stateless with respect to the last source, so it can never get
stuck.

## Changes

### `lib/ui/bar/recording_bar.dart`
- Remove the `deviceMode`, `deviceAudioEnabled`, and `onDeviceAudioTap` constructor
  parameters and their doc comments.
- Remove the `if (deviceMode) … else …` swap; always render `_SystemAudioControl`.
- Delete the `_DeviceAudioControl` widget.

### `lib/ui/bar/recording_bar_screen.dart`
- Remove the `deviceMode` computation in `_buildBar` and stop passing the three
  removed params to `RecordingBar`.
- Remove the `_deviceAudio` field and the `_onDeviceAudioTap` method.

### `lib/state/recording_action_router.dart`
- Delete `deviceAudioEnabledProvider`.
- In `doStart`'s device branch, pass `captureDeviceAudio: true` directly instead of
  reading the provider.

### Unchanged (intentionally)
- `RecordingController.startDeviceRecording({required bool captureDeviceAudio, ...})`
  keeps its parameter — it's a sound controller-level API and is exercised with both
  `true`/`false` by `recording_device_test.dart`. Only the *UI toggle* is removed; the
  router now always passes `true`.
- `systemAudioControllerProvider` already preserves the user's selection across source
  switches (it is never cleared), so Display → Device → Display keeps the choice. The
  fix is that the control is also never hidden.
- The mic control is unchanged and works for both screen and device recordings.

## Behavioral result

- The bar looks identical regardless of the last recording's source.
- Display → Device → Display: mic + system-audio choices stay intact and visible.
- A device (iPhone/iPad) recording ignores system audio (none exists over USB) and
  always captures the device's own audio + the selected mic.

## Trade-off

You can no longer record a phone's video *without* its audio from the bar — device
audio is always on. This is acceptable per the issue ("a device recording inherently
includes its audio") and the user's confirmation that device-recording audio behavior
"is good."

## Tests

- Rewrite `test/ui/bar/recording_bar_device_mode_test.dart`: the device-mode swap no
  longer exists. Assert the bar always renders `_SystemAudioControl` (via
  `Key('bar-system-audio')`) and never a device-audio control, regardless of the
  selected source; keep the test that tapping the Device chip fires
  `onPickMode(BarSourceMode.device)`. Rename the file to reflect that device mode is
  gone (e.g. `recording_bar_audio_controls_test.dart`).
- `test/state/recording_action_router_test.dart` and
  `test/state/recording_device_test.dart`: keep the `captureDeviceAudio` fake-platform
  param. Remove any reference to the deleted `deviceAudioEnabledProvider`; the router
  now hardcodes `true`.
- Run `melos test` (or the package's `flutter test`) + `flutter analyze` to confirm
  green.
