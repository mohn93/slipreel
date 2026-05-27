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
