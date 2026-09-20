# Slipreel SEO action plan — implementation record

Date: 20 September 2026

## Observed search state

Google Search Console for the `slipreel.app` domain property showed:

- 5 web-search clicks, 9 impressions, 55.6% CTR, and average position 1.4 over the available three-month window.
- 1 indexed page and 9 not-indexed URLs in the page-indexing overview.
- The submitted sitemap was successful, last read 9 September 2026, and reported 9 discovered pages.
- Eight sitemap URLs were classed as `Discovered – currently not indexed`; each showed `Last crawled: N/A`.
- URL Inspection confirmed that `/` is indexed and has six valid video enhancements.
- URL Inspection reported both `/guide` and `/screen-studio-alternative` as unknown to Google, with no crawl, referring sitemap, or selected canonical recorded.
- Search Console had no Core Web Vitals field-data report for the property yet.

This makes crawl discovery and indexation the immediate growth gate. There was no observed robots.txt, noindex, canonical, or fetch rejection for the affected pages.

## Performance baseline

Three Lighthouse 12.8.2 mobile runs against the live homepage produced:

| Metric | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Performance | 93 | 91 | 94 | 93 |
| FCP | 1.79 s | 2.03 s | 1.71 s | 1.79 s |
| LCP | 3.03 s | 3.17 s | 2.98 s | 3.03 s |
| CLS | 0.006 | 0.006 | 0.006 | 0.006 |
| TBT | 17.5 ms | 10.5 ms | 20 ms | 17.5 ms |

The LCP element was the hero poster. It was discoverable in the initial HTML, eager, and marked `fetchpriority="high"`. The remaining simulated LCP time was dominated by response/resource latency rather than blocking JavaScript, so this pass preserves the existing first-paint implementation.

## Implemented in `codex/seo-action-plan`

- Updated the static homepage/download fallback and changelog to the actual current release, 1.0.18, with factual notes derived from the tagged release commits.
- Added an SEO contract test that keeps the homepage, downloads page, and single `Latest release` changelog badge on one version.
- Added real Slipreel editor screenshots, descriptive captions, image alt text, review methodology, and stronger support-page links to all four comparison pages.
- Added missing Twitter image alt metadata to all comparison pages.
- Refreshed sitemap `lastmod` only for pages changed in this implementation.
- Added HSTS, nosniff, frame, referrer, permissions, and report-only CSP headers to the production Caddy include and nginx reference configuration.
- Added an explicit `video/webm` MIME mapping so `nosniff` can be enabled safely.
- Preserved the existing mobile hero implementation because the measured page has excellent CLS/TBT and a stable 91–94 Lighthouse score.

## Validation

- `python3 scripts/site-seo.test.py` — 8 passed
- `bash scripts/site-lint.sh` — clean
- `bash scripts/site-lint.test.sh` — passed
- `bash scripts/deploy-site.test.sh` — passed
- `node --test site/assets/js/*.test.js` — 45 passed
- Desktop browser review confirmed the new comparison evidence section, feature table, methodology note, and support links render in the intended order.
- `git diff --check` — clean

Production was confirmed to run Caddy. The checked-in Caddy include must be installed and validated with `caddy validate` before reloading. The nginx file remains a reference for any future server migration.

## Rollout gate

1. Review and merge/deploy the static site changes.
2. Install the updated Caddy include on the production host, run `sudo caddy validate --config /etc/caddy/Caddyfile`, and reload only after it passes.
3. Verify live headers, WebM MIME type, canonical tags, sitemap dates, comparison images, and release copy.
4. Resubmit `sitemap.xml` and request indexing for `/guide` and the four comparison pages in Search Console.
5. Recheck URL Inspection and the page-indexing report after Google has had time to crawl. A submitted request is not evidence of indexation.

Search Console resubmission and indexing requests were intentionally not sent before the updated pages are live.
