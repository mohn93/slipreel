# Slipreel landing page — design

Date: 2026-07-27
Status: approved

## Goal

Ship a marketing landing page at `https://slipreel.app` that sells Slipreel to
anyone making product demos, and gives the existing `slipreel.app` root a
purpose beyond serving `appcast.xml` and DMGs.

Today the domain's webroot contains only `appcast.xml` and `download/`. The
root returns 404, including for users who click Settings -> Website inside the
shipped app.

## Constraints

1. **The release pipeline is untouchable.** `.github/workflows/release-macos.yml`
   rsyncs the DMG and appcast into `/var/www/slipreel/` with no `--delete`, and
   prunes only `Slipreel-*.dmg` inside `download/`. The site must be purely
   additive to that webroot, and site deploys must never use `--delete`.
2. **No changes to `SUFeedURL`.** v1.0.0 and v1.0.1 are already installed in the
   wild pointing at `https://slipreel.app/appcast.xml`. The site cannot move,
   rename, or shadow that path.
3. **No build step.** The repo is a Flutter/melos monorepo. The site is hand-written
   HTML/CSS/JS with no Node toolchain and no framework.
4. **No third-party requests.** Fonts are self-hosted. No analytics, no CDN, no
   cookie banner. Every byte comes from `slipreel.app`.
5. **Only claim features that exist in the code.** Verified present: keystroke
   overlay with an editable timeline lane, on-device captions (whisper.cpp),
   camera/facecam, device frames, wallpapers, audio waveforms, 3D tilt, zoom
   movements, cut tool, mic + system audio tracks.

## Audience and positioning

Broad: anyone making product demos — founders, marketers, designers, developers.
The visual proof skews technical because that is what the real screenshots will
show, but the copy does not narrow to developers.

Category is "polished recorder" (Screen Studio, FocuSee). Price undercuts
Screen Studio's subscription-only model by offering a lifetime option, which the
category leader publicly regrets removing.

## Commercial model

- **$79/year** or **$149 lifetime**, presented as two cards.
- Framed as **early access / founding price**.
- Payment via **Stripe**. Checkout links are placeholders (`#`) until supplied;
  swapping them is a one-line change per card.
- The app has **no license enforcement today**. The page must not imply an
  instant key. Pricing copy and FAQ state that buyers are founding customers and
  receive a license key when licensing ships. The free DMG download stays
  available and prominent.

## Page architecture

1. **Nav** — sticky, backdrop-blurred. Logo, Features, Pricing, FAQ, Download.
2. **Hero** — headline, subhead, dual CTA (Download for macOS / See pricing),
   live version badge, product shot with cursor trail and aurora.
   - H1: "Screen recordings that look like they took a week."
   - Sub: "Slipreel auto-zooms, smooths your cursor, frames your app, and
     captions it — the moment you stop recording."
3. **Trust strip** — Notarized by Apple, Apple Silicon + Intel, on-device,
   auto-updating.
4. **Theater** — a pinned app window while copy advances through five beats:
   auto-zoom, cursor, frames and wallpapers, keystrokes, captions.
5. **Deep dives** — alternating sections: timeline and cut tool, two audio
   tracks, camera, export.
6. **Feature grid** — 16 long-tail items, icon plus label.
7. **Built like a Mac app** — ScreenCaptureKit, on-device captions, crash
   recovery, auto-update.
8. **Pricing** — two cards plus early-access banner.
9. **FAQ** — 9 questions including early access, lifetime terms after year one,
   system requirements, and caption privacy.
10. **Final CTA + footer** — download, `hello@slipreel.app`, Becoming
    Ventures, LLC, copyright. No social links, no changelog link (raw appcast
    XML is not a user-facing changelog).

## Visual system

- Canvas `#08080C`. Indigo aurora from the app icon ramp `#6C5CE7 -> #4A3FC7`,
  built from radial and conic gradients. Film grain overlay to prevent banding.
- Product window sits in a pool of spilled light with a long soft shadow.
- Inter Variable, self-hosted woff2, subset to Latin. Tight large display sizes,
  calm body copy.
- Dark only. The page matches the app's own dark UI; there is no light mode.

## Signature interactions

1. **Hero cursor trail** — canvas layer renders Slipreel's smoothed,
   motion-blurred cursor trail following the visitor's pointer. Desktop only.
2. **Scroll-driven auto-zoom** — the auto-zoom beat pushes into a cursor hotspot
   using the app's easing curve, holds, releases.
3. **Pinned theater** — window locked, visuals swap beneath advancing copy, thin
   progress rail.
4. **Keycap animation** — keycaps animate in and fade with the app overlay's
   timing.

All four are gated behind `prefers-reduced-motion: reduce`. With motion
disabled the page renders as a static document with no loss of information.

## Download button behaviour

The Download CTA and version badge fetch `/appcast.xml` on load, parse the first
`<item>`, and use its `<enclosure url>`, `<sparkle:shortVersionString>`, and
`length` to set the href and render "vX.Y.Z · NNN MB".

This makes the page self-maintaining: a release updates the appcast, and the
page follows. If the fetch fails or the feed is malformed, the button falls back
to a hardcoded href baked in at build time, and the badge renders without a
version.

Rationale: one source of truth shared with in-app updates, and zero changes to
the release pipeline.

## Technical structure

```
site/
  index.html
  assets/
    css/site.css
    js/site.js
    img/*.webp
    fonts/*.woff2
scripts/deploy-site.sh
```

`deploy-site.sh` rsyncs `site/` to `deploy@94.156.144.73:/var/www/slipreel/`
over SSH. **No `--delete`.** Stale assets accumulate harmlessly; `appcast.xml`
and `download/` can never be removed by a site deploy.

Budget: under 150 KB of CSS plus JS uncompressed. Images WebP. Hero image
preloaded. No render-blocking JS.

Accessibility: semantic landmarks, AA contrast on the dark canvas, visible focus
rings, alt text on every image, keyboard-reachable nav and FAQ.

SEO: title, meta description, Open Graph and Twitter card image, favicon derived
from the app icon, `SoftwareApplication` JSON-LD carrying name, operating
system, price, and download URL.

## Screenshots

Real UI only. An empty editor is not usable as marketing, so capturing requires
a short throwaway recording loaded into the editor with a timeline, waveform,
zoom regions, and a wallpaper applied.

Capture happens on the author's Mac by driving the installed Slipreel 1.0.1,
with explicit permission at the time, and with agreement on what is safe to have
on screen. Captured images are cropped, converted to WebP, and committed under
`site/assets/img/`.

A hero video may replace the hero still later. The hero markup uses a
`<video poster>`-shaped container so the swap is a markup change with no layout
work.

## Out of scope

- License key generation, validation, or any in-app purchase gate.
- Stripe account setup, products, or webhooks.
- Analytics, email capture, and any backend.
- A blog, docs, or changelog page.
- Cloudflare Email Routing setup for `hello@slipreel.app`. The address is
  referenced by the page; routing must be configured separately or the address
  will bounce.

## Success criteria

- `https://slipreel.app/` serves the page over HTTPS.
- `https://slipreel.app/appcast.xml` and `/download/Slipreel-*.dmg` are byte-identical
  before and after a site deploy.
- Download button resolves to the newest DMG with no hardcoded version.
- Page is fully readable and navigable with JS disabled and with
  `prefers-reduced-motion: reduce`.
- No network request leaves `slipreel.app`.
