#!/usr/bin/env bash
# Deploy the marketing site to slipreel.app.
#
# The target webroot is SHARED with the release pipeline
# (.github/workflows/release-macos.yml writes appcast.xml and download/*.dmg
# there, as the unprivileged `deploy` user). Two prohibitions follow from that,
# and both exist to keep the live Sparkle update feed publishable:
#
#   1. Never pass rsync's removal flags. Stale site assets accumulate
#      harmlessly; a removed appcast would break auto-update for every
#      installed copy of Slipreel.
#   2. Never preserve ownership, group or mode on the destination. If the SSH
#      target resolves to root, rsync happily rewrites the webroot directory's
#      owner/group/mode from whatever the local checkout happens to carry,
#      which strips `deploy`'s write permission on the directory. The next
#      release would then upload the DMG but fail to publish the appcast
#      pointing at it — the same silent update outage, reached by a different
#      route. Hence -rltv plus the explicit no-preserve flags below instead of
#      -a (which implies -p -o -g).
#
# scripts/deploy-site.test.sh enforces both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${SITE_DIR:-$ROOT/site}"
# Default matches the user the release workflow deploys as, so a site deploy
# and a release deploy leave the shared webroot owned consistently. Overridable
# via DEPLOY_TARGET. (Do not default to a personal SSH host alias: those live
# only in one machine's ~/.ssh/config and several resolve to root.)
TARGET="${DEPLOY_TARGET:-deploy@94.156.144.73}"
REMOTE_ROOT="${DEPLOY_ROOT:-/var/www/slipreel}"

[[ -f "$SITE/index.html" ]] || {
  echo "ERROR: no index.html in $SITE — refusing to deploy" >&2
  exit 1
}

# Optional deploy config (gitignored). Currently just SITE_POSTHOG_KEY, which
# is injected into ph-config.js below. Never rsync'd (excluded), so the key
# stays off the webroot and out of git.
if [[ -f "$SITE/.env" ]]; then
  set -a; . "$SITE/.env"; set +a
fi

# No --chmod: macOS ships openrsync, which rejects the flag outright and
# aborts the transfer. Permissions on the destination are left to the remote
# umask; content is all this script is responsible for.
rsync -rltv --no-perms --no-owner --no-group \
  --exclude 'package.json' \
  --exclude '*.test.js' \
  --exclude '.env*' \
  --exclude '.DS_Store' \
  "$SITE/" "$TARGET:$REMOTE_ROOT/"

echo "deploy-site: $SITE -> $TARGET:$REMOTE_ROOT"

# Inject the (public) PostHog key into the deployed ph-config.js. The committed
# copy exports an empty string; this overwrites the served copy only, so the
# key never lives in git. Skipped cleanly when unset or malformed.
if [[ -n "${SITE_POSTHOG_KEY:-}" ]]; then
  if [[ "$SITE_POSTHOG_KEY" =~ ^phc_[A-Za-z0-9]+$ ]]; then
    printf "export const POSTHOG_KEY = '%s';\n" "$SITE_POSTHOG_KEY" \
      | ssh "$TARGET" "cat > '$REMOTE_ROOT/assets/js/ph-config.js'"
    echo "deploy-site: injected SITE_POSTHOG_KEY into ph-config.js"
  else
    echo "deploy-site: SITE_POSTHOG_KEY is set but not a phc_ key — skipping" >&2
  fi
fi
