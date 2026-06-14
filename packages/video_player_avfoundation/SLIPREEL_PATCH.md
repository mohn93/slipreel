# Slipreel vendored video_player_avfoundation

Vendored copy of `video_player_avfoundation` (see `pubspec.yaml` for version),
overridden via melos workspace path resolution so we can patch the macOS
texture player.

## Why
The editor preview draws a synthetic cursor at the AVPlayer **clock** position
while the texture lags under decode load, so the cursor leads the video. The
stock plugin discards the presented-frame time (`itemTimeForDisplay:NULL`). Our
patch captures it and exposes the instantaneous latency over a
`slipreel/video_sync` method channel; Dart smooths it and shifts the preview
cursor back.

## The patch (re-apply after any upgrade)
1. `darwin/.../FVPTextureBasedVideoPlayer.m`
   - Add ivar `@property(nonatomic, assign) CMTime lastPresentedItemTime;`.
   - In `copyPixelBuffer`, change `itemTimeForDisplay:NULL` to capture a real
     `CMTime` and store it to `self.lastPresentedItemTime` when a buffer is
     returned.
   - Add `- (nullable NSNumber *)displayLatencyMicros;` returning
     `currentTime − lastPresentedItemTime` in micros, clamped >= 0, nil if either
     CMTime is invalid.
   - Declare `displayLatencyMicros` in `FVPTextureBasedVideoPlayer.h`.
2. `darwin/.../FVPVideoPlayerPlugin.m`
   - In `registerWithRegistrar:`, register a `slipreel/video_sync`
     `FlutterMethodChannel`; handle `getDisplayLatencyMicros(playerId)` by
     looking up `_playersByIdentifier[playerId]` and calling
     `displayLatencyMicros` when it is an `FVPTextureBasedVideoPlayer`.
   - Retain the channel on a plugin property so it isn't deallocated.

Keep this file in sync with `packages/screen_recorder` Dart code
(`DisplayLatencyProbe`, channel name `slipreel/video_sync`).
