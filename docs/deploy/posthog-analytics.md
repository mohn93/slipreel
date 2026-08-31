# PostHog analytics — website setup

Web analytics for slipreel.app via PostHog (US cloud), served **first-party**
through an nginx reverse proxy so the marketing pages make zero third-party
requests (site-lint rule #1) and tracker blockers can't drop the data.

## What's in the repo

- [`site/assets/js/analytics.js`](../../site/assets/js/analytics.js) — the tuned
  snippet. Autocapture and session replay are **off**; it captures pageviews +
  pageleave only, loads on `requestIdleCallback` (off the LCP path), and posts
  to `/ingest` on the current origin. No `posthog.com` URL literal (the host is
  built from `location.origin`).
- A `<script type="module" src="assets/js/analytics.js">` tag on every page.
- The `/ingest/` reverse-proxy blocks in
  [`server/deploy/nginx-site.conf`](../../server/deploy/nginx-site.conf) (the
  pre-TLS reference copy).

## Two things you must do to make it live

### 1. Set the project API key `[you]`

Edit `site/assets/js/analytics.js` and replace `phc_REPLACE_ME` with your
project's **public** key (Project Settings → API keys → "Project API Key",
starts with `phc_`). It is write-only and safe to commit / ship in client code.
Until it's set, the module no-ops (nothing loads).

### 2. Add the proxy to the LIVE nginx config `[you]`

`scripts/deploy-site.sh` only rsyncs site files — it does **not** touch nginx.
certbot rewrote the live config into a `listen 443` server block, so the two
`location ^~ /ingest...` blocks from `nginx-site.conf` must be added to that
live block on the VPS:

```bash
# on 94.156.144.73
sudo nano /etc/nginx/sites-enabled/slipreel   # or wherever the site vhost lives
# paste the two `location ^~ /ingest/static/` and `location ^~ /ingest/` blocks
# into the server{} that has `listen 443 ssl` for slipreel.app
sudo nginx -t && sudo systemctl reload nginx
```

Cloudflare (in front of the origin) proxies `/ingest/*` to the box like any
other path — no Cloudflare config needed. POST ingestion isn't cached; the
static `array.js` under `/ingest/static/` is cacheable and carries its own
`Cache-Control`.

## Verify

```bash
# asset path -> PostHog CDN via nginx (expect 200 + JS)
curl -sI https://slipreel.app/ingest/static/array.js | head -5
# ingestion decide endpoint reachable (expect 200/JSON, not a 404 from the site)
curl -s "https://slipreel.app/ingest/flags/?v=2" -o /dev/null -w '%{http_code}\n'
```

Then load slipreel.app and confirm a `POST /ingest/e/` (or `/i/v0/e/`) fires in
the Network tab, and the event lands in PostHog → Activity. If you get the
site's HTML 404 instead of PostHog JSON, the `location ^~ /ingest/` block isn't
in the server block that actually serves 443.

## Notes

- Region is **US** (`us.i.posthog.com` / `us-assets.i.posthog.com`). If you ever
  move to EU, swap both upstream hosts in `nginx-site.conf` and reload.
- `person_profiles: 'identified_only'` keeps anonymous pageviews cheap; combined
  with `persistence: 'localStorage'` there's no analytics cookie, so no consent
  banner is required for it.
- To track a conversion, call `window.posthog?.capture('download_clicked')` from
  the relevant handler (e.g. in `site.js`'s download hydration).
