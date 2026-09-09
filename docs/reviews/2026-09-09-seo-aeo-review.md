# Slipreel SEO and answer-engine review

Reviewed 9 September 2026. Scope: all 14 HTML pages, nine indexable public pages, robots.txt, sitemap, llms.txt, structured data, internal links, live HTTP routing, mobile layout, public performance, and search measurement access.

**Verdict:** the live site has strong technical foundations, but several accuracy and measurement issues deserved correction before treating SEO/AEO as finished. The candidate changes are implemented and tested on `codex/seo-aeo-review`. They are **not deployed or merged**. Scores below describe the existing live site, not the candidate.

## Live measurements

[Google PageSpeed report](https://pagespeed.web.dev/analysis/https-slipreel-app/vfe9iqtqoz?form_factor=mobile):

| Metric | Mobile | Desktop |
| --- | --- | --- |
| Performance | 99 | 99 |
| Basic SEO audit | 100 | 100 |
| Accessibility | 95 | 95 |
| Best practices | 96 | 96 |
| Largest Contentful Paint | 2.0 s | 0.5 s |
| Total Blocking Time | 70 ms | 10 ms |
| Cumulative Layout Shift | 0 | 0 |

These are single-run laboratory results. Google reports **no field data** for real-user Core Web Vitals; the lab results do not establish a field pass, rankings, or conversions.

[Google Rich Results Test](https://search.google.com/test/rich-results/result?id=NLF7zw1Jd9uuz95AGuUnAA) successfully crawled the live homepage and detected eight valid items: one organization, one software application, and six videos. The app has an optional missing `aggregateRating` warning. Every video has optional invalid datetime/missing timezone warnings. No customer ratings were invented to satisfy the optional field.

## Findings and prepared fixes

| Priority | Finding | Candidate change / disposition |
| --- | --- | --- |
| High | Analytics events rejected by `/ingest/e/` with HTTP 400. The privacy scrubber redacts the SDK's public `properties.token` ingestion key. | Restore only the configured public project key after scrubbing. Regression test proves URL tokens and nested authentication secrets remain redacted, and input events are not mutated. Live delivery still needs post-deploy verification. |
| High | `llms.txt` still says license activation and model download are the app's only network calls, and describes a lifetime purchase that works forever without explaining activation renewal. | Align with the already corrected privacy policy: update checks, optional analytics/diagnostics/feedback, account association, one year of updates, two Macs, and online activation at least every 14 days. Add links to authoritative product/support pages and explicit platform/export/sharing limits. |
| Medium | Screen Studio comparison uses “own outright”/“lifetime” language without nearby renewal conditions. Some comparisons imply all network activity is absent. | Explain the one-time license precisely and put activation/update terms on all four comparison pages. Restrict local-processing claims to recording media. |
| Medium | Loom editing is described only as “Basic trim”; unrelated ScreenFlow pricing footnotes appear on Loom/Screen Studio pages. QuickTime has no supporting source links. | Describe trim/stitch and transcript editing by plan, remove stray footnotes, and add Apple references. Competitor prices were checked against their own current pages. |
| Medium | Public clean URLs and `.html` aliases both return HTTP 200; `/guide/` returns 404. Internal links mix both URL styles. | Use canonical internal links. Prepare a narrowly scoped Caddy redirect snippet for public aliases, preserving query strings. Auth/checkout paths are excluded. Tested 55 cases on an isolated localhost Caddy listener. Production routing is unchanged. |
| Medium | Changelog labels 1.0.14 latest although 1.0.15 is available. | Publishable 1.0.15 entry describes shipped save, feedback, and privacy improvements; latest badge moved to that entry. |
| Medium | Support pages lack social previews and useful structured page context. | Add Open Graph/Twitter metadata plus WebPage/BreadcrumbList data to guide, downloads, changelog, and privacy pages. |
| Medium | Homepage title is entirely a slogan, leaving its software category implicit in the result title. | Descriptive “Mac Screen Recorder with Auto-Zoom & Captions” title and a direct product definition in the hero. Preserve the visual headline. |
| Medium | Pricing schema groups recurring and one-time prices as a range and points to the noindex checkout page. | Explicit monthly and one-time offers, license descriptions, and links to the visible public pricing section. Existing markup was valid; this is a clarity improvement. |
| Low | FAQ JSON-LD differs from current visible answers. | Synchronize the five FAQ blocks with visible text and add a parity regression check. |
| Low | Sitemap omits the indexable privacy policy and has stale dates. | Include exactly the nine indexable canonical pages and dates reflecting this content revision. Keep checkout/account pages out. |
| Low | Missing site-name entity. | Add WebSite identity connected to the existing organization. |
| Low | Six video upload dates fail Google's optional datetime/timezone checks. | Normalize the existing recorded publication day to UTC midnight and add durations measured with ffprobe. This preserves day-level metadata; it does not recover the exact historical upload time. |
| Low | Footer comparison label fails text contrast. | Use the existing higher-contrast text color. Version the stylesheet URL to avoid stale cached styling. |
| Low | Homepage poster is not explicitly prioritized. | Add high-priority image preload for earlier discovery. Recheck performance after deploy; baseline is already excellent. |
| Medium | Cancellation page still imports analytics, despite the intended separation of checkout from marketing telemetry. | Remove import, add no-referrer, and extend the route guard/tests to cancellation URLs. |

## Crawlability and indexing

- Public content is server-rendered static HTML. Feature descriptions, prices, FAQs and comparison tables are present without executing JavaScript.
- Public pages have self-referencing canonical URLs. All nine candidate public pages have one H1, nonempty distinct titles, descriptions, share previews, and parseable JSON-LD.
- Robots.txt allows search crawlers; public pages permit snippets and image previews. No new bot/training permission policy was introduced.
- GET checks with Googlebot, Bingbot, OAI-SearchBot, PerplexityBot and GPTBot user-agent strings returned HTTP 200. User-agent probes do not authenticate those crawlers' actual network origin. Google's successful live Rich Results fetch independently confirms its inspection crawler can reach the homepage.
- A Python-urllib user agent received 403 while curl and the search-agent probes received 200. Do not infer that every automated client is allowed, and do not disable the CDN's protections merely to accommodate a generic script.
- A genuinely missing page returns HTTP 404; it does not masquerade as the homepage with HTTP 200.
- The `www` hostname did not resolve in this environment. Current canonical URLs and internal links use the apex domain consistently. Adding a www-to-apex redirect is a useful follow-up for people who type www, requiring DNS/edge setup; it is not evidence that the apex is unindexable.
- Pricing remains deliberately noindex because `/pricing` is a checkout form and participates in activation flows. Public prices and complete terms are available on the indexed homepage. Noindex pages remain crawlable so bots can read their directives.
- Download history is enhanced by JavaScript and has a noscript latest-download link. Release notes and installation instructions are ordinary HTML. The personalized license filter should not become indexed personalized content.

## Answer-engine readiness

The useful strengths are direct product definitions, substantive comparison tables, explicit cases where a competitor is a better fit, visible FAQs, screenshots/video demonstrations, and an ordinary HTML installation guide. Candidate changes improve consistency among those sources and the auxiliary llms.txt file.

The guide now answers screen/audio and on-device-caption questions more directly. The machine-readable summary explains macOS-only support, three trial exports, lack of built-in cloud hosting, GIF limits, and periodic online license renewal. Those constraints help an answer engine recommend the product accurately rather than overpromise.

Google says its AI search features use the same SEO foundations and do not require special AI files or special schema. Treat llms.txt as an optional factual summary, not an indexing submission or a promise of AI citations. FAQ markup is useful descriptive data, but this software site should not expect Google's restricted FAQ rich-result treatment. [Google AI guidance](https://developers.google.com/search/docs/appearance/ai-features), [FAQ/HowTo guidance](https://developers.google.com/search/blog/2023/08/howto-faq-changes).

## Content, credibility, and growth

The site covers branded, competitor-alternative, download, setup, and basic pricing intent. A reasonable next content investment is a small number of original task walkthroughs using real Slipreel projects: record Mac system audio, add local captions, and turn a screen capture into a short product demo. Each should include the actual steps, an example output, limitations, and troubleshooting. A collection of generic AI-written keyword pages would add much less value.

The legal publisher, support address, privacy policy, refund window, platform requirements, signed/notarized distribution, and license limitations are available. Maintain consistency as releases change. Collect genuine customer evidence before adding testimonial or aggregate-rating markup. No backlink-quality audit, search-volume dataset, or independent review corpus was available in this review; no authority score is claimed.

Competitor sources checked: [Screen Studio](https://screen.studio/), [Loom pricing and features](https://www.loom.com/pricing), [ScreenFlow store](https://www.telestream.net/screenflow/store.asp), [Apple QuickTime screen recording](https://support.apple.com/guide/quicktime-player/record-your-screen-qtp97b08e666/mac). These are time-sensitive comparisons, not promises that competitors' pricing will remain fixed.

## Page experience and validation limits

Candidate homepage and guide were visually reviewed on desktop/mobile, and all nine public pages were checked at 390px viewport width with no horizontal overflow. Native FAQ disclosures, semantic headings, image alternative text, image dimensions, and reduced-motion styles are already present.

The PageSpeed video-caption warning is unscored; ffprobe confirms the hero MP4 contains no audio stream. Its visual purpose is also described in text. Adding an empty caption track merely to satisfy an audit would not help visitors.

Remaining low-priority lab suggestions include responsive image sizing, media/cache budgets, and small CSS/JS savings. The media-heavy homepage transferred about 3.9 MiB in the mobile run. Asset cache lifetimes are intentionally modest for unversioned resources. Do not blindly apply immutable year-long caching to mutable assets or the latest installer. Security-header suggestions were reported by Lighthouse, but changing CSP/COOP site-wide requires separate compatibility checks across authentication, payments and telemetry; this review does not claim a full security audit.

## Measurement gap and release follow-through

The available signed-in Google account has no accessible Slipreel property in Search Console. Consequently, sitemap submission, indexed/excluded URLs, Google-selected canonicals, impressions, queries, manual actions and actual search performance are **unverified**, not assumed healthy. A public site-search probe also did not establish indexed coverage; Search Console is the appropriate evidence source. Bing Webmaster Tools and AI citation traffic have not been verified.

Before calling search operations complete:

1. Deploy the candidate site and apply the Caddy snippet **inside the existing Slipreel site block, outside its static handle**. Validate/reload with rollback available; preserve the current proxy, download and appcast configuration. The regular site deployment script does not install this snippet.
2. Verify public redirects, nine-page sitemap coverage, fresh HTML/assets, and a successful normal analytics pageview. Re-run PageSpeed and Rich Results against production. Current scores are baseline only.
3. Connect or grant access to the correct Search Console property; submit `/sitemap.xml` and inspect the homepage and key comparison pages. Do the corresponding Bing setup if not already configured.
4. Assess search impressions, qualified visits and trial downloads once enough traffic accumulates. Rankings, indexing, and AI citations cannot be greenlighted solely from source changes or a Lighthouse score.

## Reproducible checks

- `npm test --prefix site`: 44 passed, including public analytics-key preservation and credential redaction.
- `python3 scripts/site-seo.test.py`: seven checks covering the entire public-page contract, FAQ parity, offers, videos, sitemap, links/fragments, and noindex account routes. Integrated into `melos run test_site` for CI.
- Site lint, lint regression tests, deployment safety tests, and `git diff --check`: passed.
- Caddy configuration validation: passed. Isolated route integration: 55 passed, including query preservation and unchanged auth URLs.
- Raw supporting outputs and measured scores: [evidence directory](seo-aeo-2026-09-09/).

No new app binary was built, no production configuration was changed, and no new tracking service or property access was created during this review.
