#!/usr/bin/env bash
# Deploy the marketing site to slipreel.app.
#
# The target webroot is SHARED with the release pipeline
# (.github/workflows/release-macos.yml writes appcast.xml and download/*.dmg
# there). This script is therefore strictly additive: the delete flag must
# never be passed to rsync.
# Stale site assets accumulate harmlessly; a deleted appcast would break
# auto-update for every installed copy of Slipreel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${SITE_DIR:-$ROOT/site}"
TARGET="${DEPLOY_TARGET:-trader-vps}"
REMOTE_ROOT="${DEPLOY_ROOT:-/var/www/slipreel}"

[[ -f "$SITE/index.html" ]] || {
  echo "ERROR: no index.html in $SITE — refusing to deploy" >&2
  exit 1
}

# No --chmod: macOS's bundled openrsync does not apply file-level chmod
# overrides (only directory-level), so this relies on source files already
# carrying the right permissions (644/755 via git checkout + umask).
rsync -av \
  --exclude 'package.json' \
  --exclude '*.test.js' \
  --exclude '.DS_Store' \
  "$SITE/" "$TARGET:$REMOTE_ROOT/"

echo "deploy-site: $SITE -> $TARGET:$REMOTE_ROOT"
