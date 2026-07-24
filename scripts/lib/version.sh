#!/usr/bin/env bash
# Shared version helpers for the release pipeline. Sourceable, no side effects.

# Sparkle decides "is the appcast newer than what's installed?" by comparing
# the appcast's sparkle:version against the running app's CFBundleVersion.
# Flutter maps CFBundleVersion to the build number, so it MUST increase every
# release. Derive a strictly-increasing integer from the semver instead of
# hand-bumping pubspec's +N. Assumes minor and patch < 1000 (validated).
derive_build_number() { # derive_build_number <major.minor.patch>
  local v="${1:-}" major minor patch
  IFS=. read -r major minor patch <<<"$v"
  if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
    echo "derive_build_number: version must be MAJOR.MINOR.PATCH integers, got '$v'" >&2
    return 1
  fi
  if (( minor >= 1000 || patch >= 1000 )); then
    echo "derive_build_number: minor/patch must be < 1000 for a monotonic build number (got '$v')" >&2
    return 1
  fi
  echo $(( major * 1000000 + minor * 1000 + patch ))
}
