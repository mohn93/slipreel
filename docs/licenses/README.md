# Third-party native binaries

Slipreel bundles two CLI binaries in `Slipreel.app/Contents/Helpers/`,
built by `scripts/build-native-deps.sh` (pinned versions at the top of
that script). The license texts and the exact build provenance
(`BUILD_INFO.txt`: versions, source URLs, configure/cmake lines) ship
inside the app at `Contents/Resources/licenses/`.

## ffmpeg / ffprobe — LGPL v2.1+

Built from the official source release with native components only: no
external libraries, no `--enable-gpl`, no `--enable-nonfree`. Hardware
H.264 encoding uses Apple VideoToolbox. Under the LGPL we must (and do)
ship the license text and state where to obtain the corresponding
source: the exact tarball URL and full configure line are recorded in
the bundled `BUILD_INFO.txt`. No ffmpeg source modifications are made.

## whisper-cli (whisper.cpp) — MIT

Built from the pinned upstream tag with Metal support embedded on Apple
Silicon. MIT requires shipping the copyright notice + license text,
which rides in `Contents/Resources/licenses/WHISPER-LICENSE-MIT`.

## Updating

Bump the pinned version in `scripts/build-native-deps.sh`, re-run it
(both binaries re-verify: universal, statically self-contained, smoke
runs), rebuild the app. Binary updates reach users through app updates.

Do a **clean** build (`flutter clean` first) after changing the vendored
binaries. An incremental build can leave the app's code signature stale
(`codesign --verify` reports the changed Helpers binaries as "modified")
because Xcode's final signing step is up-to-date-skipped when only our
copy phase's outputs changed. A clean build — the distribution path —
always re-seals correctly.
