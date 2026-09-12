#!/usr/bin/env bash
# Prepare a separate sandboxed app. No submission or public release occurs here.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: build-app-store.sh VERSION BUILD_NUMBER NEW_STAGING_DIRECTORY}"
build="${2:?Build number required}"
stage="${3:?New staging directory required}"
profile="${APP_STORE_PROFILE:?Set APP_STORE_PROFILE to the installed Mac App Store distribution profile name or UUID}"
python3 "$root/scripts/prepare-app-store.py" "$stage" --profile "$profile"
cd "$stage"
dart pub get
dart run melos bootstrap
cd packages/screen_recorder
# Use a Mac App Store provisioning profile + Apple Distribution certificate for
# distribution. Xcode automatic signing can prepare local development builds.
flutter build macos --release --build-name="$version" --build-number="$build" \
  --dart-define=SLIPREEL_DISTRIBUTION=app-store
python3 "$root/scripts/verify-app-store.py" "$PWD/build/macos/Build/Products/Release/SlipreelStore.app"
