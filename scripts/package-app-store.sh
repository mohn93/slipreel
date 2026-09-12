#!/usr/bin/env bash
# Package a verified store app; this does not upload or submit it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Usage: package-app-store.sh APP_PATH NEW_PACKAGE_PATH}"
output="${2:?New package path required}"
identity='3rd Party Mac Developer Installer: Becoming Ventures, LLC (UD7WB2694V)'
if [[ -e "$output" ]]; then
  echo 'Package destination already exists' >&2
  exit 1
fi
python3 "$root/scripts/verify-app-store.py" "$app"
productbuild --component "$app" /Applications --sign "$identity" "$output"
pkgutil --check-signature "$output"
