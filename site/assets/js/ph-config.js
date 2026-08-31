// PostHog project key — supplied at deploy time, not committed.
//
// This value is PUBLIC (a write-only ingestion key that ships in client code),
// so it is not a secret. It lives here, on its own, only so it can be injected
// from an env file instead of being hardcoded in the logic:
//
//   1. put your key in site/.env (gitignored):  SITE_POSTHOG_KEY=phc_xxx
//   2. scripts/deploy-site.sh reads it and overwrites the *deployed* copy of
//      this file with the real value.
//
// The committed value stays empty, so a plain checkout (and local dev) no-ops
// — analytics.js only initializes when this starts with "phc_".
export const POSTHOG_KEY = '';
