# Slipreel Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a dark, cinematic marketing landing page at `https://slipreel.app` that sells Slipreel at $79/yr or $149 lifetime, without disturbing the live Sparkle auto-update pipeline that shares the same webroot.

**Architecture:** A hand-written static site in `site/` — one `index.html`, one stylesheet, two ES modules — rsynced to `/var/www/slipreel/` on the existing VPS. No framework, no bundler, no third-party requests. The Download button and version badge hydrate from the live `/appcast.xml`, so the page follows releases automatically.

**Tech Stack:** HTML5, CSS (custom properties, `position: sticky`, CSS gradients), vanilla ES modules, IntersectionObserver. Dev-time only: `node --test` (Node 22, built-in runner), `cwebp`, `rsync` over SSH. None of these ship to the browser.

## How to read this plan

Load-bearing logic — the deploy script, the constraint lint, the appcast parser, the scroll engine — is given as complete code, and must be implemented as written.

Visual execution is specified as **exact design tokens + an exact markup contract + acceptance criteria**, not as line-by-line CSS. Reproducing every decorative declaration here would be longer than the stylesheet and would strip the implementer of the judgment the task needs. Where a task says "acceptance criteria", those criteria are the gate.

## Global Constraints

- **Never use `rsync --delete` against the webroot.** `/var/www/slipreel/` also holds `appcast.xml` and `download/*.dmg`, written by `.github/workflows/release-macos.yml`. A site deploy is purely additive.
- **Never move, rename, or shadow `/appcast.xml`.** Shipped apps (v1.0.0, v1.0.1) have that URL baked into `Info.plist` as `SUFeedURL`.
- **No third-party network requests.** No CDN, no Google Fonts, no analytics, no cookie banner. Every byte is served from `slipreel.app`. Enforced by `scripts/site-lint.sh`.
- **No build step and no runtime dependencies.** Files under `site/` are served exactly as committed.
- **Only claim features that exist in the code.** Verified present: keystroke overlay with editable timeline lane, on-device captions (whisper.cpp), camera/facecam, device frames, wallpapers, audio waveforms, 3D tilt, zoom movements, cut tool, mic + system audio tracks.
- **Dark only.** No light mode. Canvas `#08080C`.
- **Every motion effect is gated behind `@media (prefers-reduced-motion: reduce)`**, and the page must be fully readable and navigable with JavaScript disabled.
- **Copy rules:** no emoji anywhere. Pricing is `$79/year` and `$149 lifetime`, framed as early access. Stripe checkout hrefs are the literal placeholder `#stripe-yearly` and `#stripe-lifetime` until real links are supplied.
- **Contact address:** `hello@slipreel.app`. **Company:** Becoming Ventures, LLC.
- Run `bash scripts/site-lint.sh` before every commit from Task 2 onward. It must exit 0.

## File structure

| Path | Responsibility |
|---|---|
| `site/index.html` | The entire page. Single document, semantic sections. |
| `site/assets/css/site.css` | Design tokens, layout, components, motion, reduced-motion fallbacks. |
| `site/assets/js/appcast.js` | Pure functions: parse appcast items, pick newest, format size. Unit-tested. |
| `site/assets/js/appcast.test.js` | Node unit tests. Never deployed. |
| `site/assets/js/site.js` | Browser glue: download hydration, scroll engine, cursor trail. |
| `site/assets/fonts/*.woff2` | Self-hosted Inter Variable subset. |
| `site/assets/img/*.webp` | Product screenshots and OG image. |
| `site/package.json` | `{"private":true,"type":"module"}` so Node treats `.js` as ESM. Never deployed. |
| `scripts/deploy-site.sh` | rsync `site/` to the VPS. Never `--delete`. |
| `scripts/deploy-site.test.sh` | Asserts the deploy script cannot destroy release artifacts. |
| `scripts/site-lint.sh` | Enforces global constraints across `site/`. |
| `scripts/site-lint.test.sh` | Asserts the lint actually catches violations. |

---

### Task 1: Scaffold and a deploy path that cannot destroy releases

The riskiest thing about this project is deploying into a webroot that holds a live update feed. Prove that is safe before writing a single line of design.

**Files:**
- Create: `site/index.html` (placeholder), `site/package.json`
- Create: `scripts/deploy-site.sh`, `scripts/deploy-site.test.sh`

**Interfaces:**
- Produces: `scripts/deploy-site.sh`, honoring env `SITE_DIR` (default `<repo>/site`), `DEPLOY_TARGET` (default `trader-vps`), `DEPLOY_ROOT` (default `/var/www/slipreel`). Exits non-zero if `$SITE_DIR/index.html` is absent.

- [ ] **Step 1: Write the failing test**

Create `scripts/deploy-site.test.sh`:

```bash
#!/usr/bin/env bash
# Guards the one property that matters: a site deploy can never remove the
# release pipeline's artifacts (appcast.xml, download/*.dmg) from the shared
# webroot.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/deploy-site.sh"
rc=0
fail() { echo "FAIL: $1" >&2; rc=1; }

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || fail "deploy-site.sh is not executable"

# The critical assertion.
if grep -qE -- '--delete' "$SCRIPT"; then
  fail "deploy-site.sh must never use --delete (shared webroot holds appcast.xml + download/)"
fi

# Dev-only files must not be published.
for pat in 'package.json' '\*.test.js'; do
  grep -qE -- "--exclude[ =]'?$pat" "$SCRIPT" || fail "deploy-site.sh must exclude $pat"
done

# Refuses to deploy an empty/missing site dir instead of silently succeeding.
tmp="$(mktemp -d)"
if SITE_DIR="$tmp" DEPLOY_TARGET="invalid.invalid" "$SCRIPT" >/dev/null 2>&1; then
  fail "deploy-site.sh should exit non-zero when index.html is missing"
fi
rmdir "$tmp"

[[ $rc -eq 0 ]] && echo "deploy-site.test: all checks passed"
exit $rc
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/deploy-site.test.sh`
Expected: `FAIL: /Users/.../scripts/deploy-site.sh missing`, exit 1.

- [ ] **Step 3: Write the deploy script**

Create `scripts/deploy-site.sh`:

```bash
#!/usr/bin/env bash
# Deploy the marketing site to slipreel.app.
#
# The target webroot is SHARED with the release pipeline
# (.github/workflows/release-macos.yml writes appcast.xml and download/*.dmg
# there). This script is therefore strictly additive: no --delete, ever.
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

rsync -av \
  --exclude 'package.json' \
  --exclude '*.test.js' \
  --exclude '.DS_Store' \
  --chmod=D755,F644 \
  "$SITE/" "$TARGET:$REMOTE_ROOT/"

echo "deploy-site: $SITE -> $TARGET:$REMOTE_ROOT"
```

Make it executable: `chmod +x scripts/deploy-site.sh`

- [ ] **Step 4: Create the placeholder site**

Create `site/package.json`:

```json
{
  "private": true,
  "type": "module"
}
```

Create `site/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Slipreel</title>
</head>
<body>
<h1>Slipreel</h1>
</body>
</html>
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/deploy-site.test.sh`
Expected: `deploy-site.test: all checks passed`, exit 0.

- [ ] **Step 6: Record the pre-deploy state of the release artifacts**

Run:

```bash
ssh trader-vps 'md5sum /var/www/slipreel/appcast.xml; ls -1 /var/www/slipreel/download/'
```

Save the output. This is the baseline for the safety assertion.

- [ ] **Step 7: Deploy and verify nothing was destroyed**

Run:

```bash
bash scripts/deploy-site.sh
curl -sS -o /dev/null -w '%{http_code}\n' https://slipreel.app/
ssh trader-vps 'md5sum /var/www/slipreel/appcast.xml; ls -1 /var/www/slipreel/download/'
```

Expected: `200` from the site, and the md5 and DMG listing **identical** to Step 6. If either changed, stop and fix the script before continuing.

- [ ] **Step 8: Commit**

```bash
git add site/index.html site/package.json scripts/deploy-site.sh scripts/deploy-site.test.sh
git commit -m "feat(site): scaffold landing page and additive deploy script"
```

---

### Task 2: Design system and the constraint lint

**Files:**
- Create: `site/assets/css/site.css`
- Create: `scripts/site-lint.sh`, `scripts/site-lint.test.sh`
- Create: `site/assets/fonts/inter-variable.woff2`
- Modify: `site/index.html` (link the stylesheet, preload the font)

**Interfaces:**
- Produces: the CSS custom properties below, consumed by every later task. Utility classes `.container`, `.section`, `.btn`, `.btn--primary`, `.btn--ghost`, `.eyebrow`, `.reveal`. Background layers `.aurora`, `.grain`.
- Produces: `scripts/site-lint.sh`, honoring `SITE_DIR`. Exit 0 clean, 1 on violation.

- [ ] **Step 1: Write the failing lint test**

Create `scripts/site-lint.test.sh`:

```bash
#!/usr/bin/env bash
# The lint is a guard; this proves the guard actually fires.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/site-lint.sh"
rc=0
fail() { echo "FAIL: $1" >&2; rc=1; }

[[ -f "$LINT" ]] || { echo "FAIL: $LINT missing" >&2; exit 1; }

# The real site must pass.
bash "$LINT" >/dev/null 2>&1 || fail "site-lint.sh must pass on the real site/"

# A third-party request must be caught.
tmp="$(mktemp -d)"
mkdir -p "$tmp/assets/css"
cat > "$tmp/index.html" <<'HTML'
<!doctype html><html><head>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">
</head><body></body></html>
HTML
printf '@media (prefers-reduced-motion: reduce){*{animation:none}}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject an external host (fonts.googleapis.com)"
fi

# A missing local asset must be caught.
rm -rf "${tmp:?}"/*
mkdir -p "$tmp/assets/css"
cat > "$tmp/index.html" <<'HTML'
<!doctype html><html><head>
<link rel="stylesheet" href="assets/css/site.css">
<script src="assets/js/does-not-exist.js"></script>
</head><body></body></html>
HTML
printf '@media (prefers-reduced-motion: reduce){*{animation:none}}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject a reference to a missing local asset"
fi

# A stylesheet with no reduced-motion block must be caught.
rm -rf "${tmp:?}"/*
mkdir -p "$tmp/assets/css"
printf '<!doctype html><html><head><link rel="stylesheet" href="assets/css/site.css"></head><body></body></html>\n' > "$tmp/index.html"
printf '.a{color:red}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject CSS with no prefers-reduced-motion block"
fi

rm -rf "$tmp"
[[ $rc -eq 0 ]] && echo "site-lint.test: all checks passed"
exit $rc
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/site-lint.test.sh`
Expected: `FAIL: .../scripts/site-lint.sh missing`, exit 1.

- [ ] **Step 3: Write the lint**

Create `scripts/site-lint.sh`:

```bash
#!/usr/bin/env bash
# Enforces the landing page's global constraints:
#   1. no third-party network requests
#   2. every referenced local asset exists
#   3. the stylesheet honors prefers-reduced-motion
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${SITE_DIR:-$ROOT/site}"
rc=0
violation() { echo "site-lint: $1" >&2; rc=1; }

[[ -d "$SITE" ]] || { echo "site-lint: no such dir: $SITE" >&2; exit 1; }

# 1. External hosts. Namespace URIs in XML/JSON-LD are declarations, not
#    requests, so a small allowlist is permitted.
allow='slipreel\.app|schema\.org|www\.w3\.org|purl\.org|andymatuschak\.org'
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  grep -qE "^https?://($allow)" <<<"$url" || violation "external request: $url"
done < <(grep -rhoE 'https?://[A-Za-z0-9.:-]+' \
           --include='*.html' --include='*.css' --include='*.js' \
           "$SITE" 2>/dev/null | grep -v '\.test\.js' | sort -u)

# 2. Local assets referenced from HTML must exist on disk.
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  case "$ref" in http*|//*|\#*|mailto:*|data:*) continue ;; esac
  path="${ref%%\#*}"; path="${path%%\?*}"
  [[ -z "$path" ]] && continue
  [[ -f "$SITE/$path" ]] || violation "missing local asset: $path"
done < <(grep -rhoE '(src|href)="[^"]+"' --include='*.html' "$SITE" 2>/dev/null \
           | sed -E 's/^(src|href)="//; s/"$//' | sort -u)

# 3. Reduced motion.
for css in "$SITE"/assets/css/*.css; do
  [[ -f "$css" ]] || continue
  grep -q 'prefers-reduced-motion' "$css" \
    || violation "no prefers-reduced-motion block in $(basename "$css")"
done

[[ $rc -eq 0 ]] && echo "site-lint: clean"
exit $rc
```

- [ ] **Step 4: Install the self-hosted font**

Download Inter Variable (OFL licensed) and place the Latin subset at
`site/assets/fonts/inter-variable.woff2`. Verify it is under 120 KB:

```bash
ls -l site/assets/fonts/inter-variable.woff2
```

If a subset is unavailable, use the full variable woff2 and note the size. Do **not** reference a font CDN.

- [ ] **Step 5: Write the design system stylesheet**

Create `site/assets/css/site.css`. It **must** open with exactly these tokens:

```css
:root {
  --bg: #08080C;
  --bg-elev: #0E0E15;
  --bg-card: #12121C;
  --ink: #F5F5FA;
  --ink-dim: #A3A3B8;
  --ink-faint: #6E6E85;
  --accent: #6C5CE7;
  --accent-deep: #4A3FC7;
  --accent-glow: rgba(108, 92, 231, 0.45);
  --line: rgba(255, 255, 255, 0.08);
  --line-strong: rgba(255, 255, 255, 0.14);
  --radius: 14px;
  --radius-lg: 22px;
  --maxw: 1200px;
  --pad: clamp(20px, 5vw, 48px);
}
```

Then implement, in this order: modern reset; `@font-face` for Inter Variable with `font-display: swap`; fluid type scale using `clamp()`; `.container`/`.section` rhythm; `.btn` variants; `.eyebrow`; `.reveal` (opacity/translate, neutralized under reduced motion); the `.aurora` and `.grain` background layers; visible `:focus-visible` rings using `--accent`.

**Aurora** — a `position: fixed`, `pointer-events: none`, `z-index: 0` layer behind content, built from two or three overlapping `radial-gradient`s in `--accent`/`--accent-deep` at low alpha, heavily blurred, top-weighted.

**Grain** — a `position: fixed`, `pointer-events: none` overlay using an inline SVG `feTurbulence` data URI as `background-image` at roughly `opacity: 0.035`, `mix-blend-mode: overlay`. This prevents the gradients from banding on wide displays.

**Reduced motion** — a `@media (prefers-reduced-motion: reduce)` block that sets `animation: none !important`, `transition: none !important`, neutralizes `.reveal` to its visible state, and disables any parallax transform.

Acceptance criteria:
- All colors come from the tokens above; no raw hex outside `:root`.
- Body text on `--bg` meets WCAG AA (`--ink` and `--ink-dim` both pass at body sizes; `--ink-faint` is used only for non-essential text at 14px+).
- `.reveal` elements are fully visible when JavaScript is disabled (the JS adds a class to animate them in; the default state must not be `opacity: 0` unless a `.js` class is present on `<html>`).
- Page has zero horizontal scroll at 320px width.

- [ ] **Step 6: Wire the stylesheet into the page**

Modify `site/index.html` `<head>`:

```html
<link rel="preload" href="assets/fonts/inter-variable.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="assets/css/site.css">
```

Add `<div class="aurora" aria-hidden="true"></div>` and `<div class="grain" aria-hidden="true"></div>` as the first children of `<body>`.

- [ ] **Step 7: Run the tests**

Run: `bash scripts/site-lint.test.sh && bash scripts/deploy-site.test.sh`
Expected: both print `all checks passed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add site/assets/css/site.css site/assets/fonts/inter-variable.woff2 site/index.html scripts/site-lint.sh scripts/site-lint.test.sh
git commit -m "feat(site): design tokens, aurora background, constraint lint"
```

---

### Task 3: Navigation and hero

**Files:**
- Modify: `site/index.html`, `site/assets/css/site.css`
- Create: `site/assets/img/hero-editor.webp` (placeholder for now)

**Interfaces:**
- Consumes: tokens and utilities from Task 2.
- Produces: the markup contract below. Task 4 hydrates `[data-download-link]` and `[data-version-badge]`; Task 5 mounts the cursor trail on `[data-cursor-stage]`. These attribute names are fixed.

- [ ] **Step 1: Build the nav**

Sticky, `backdrop-filter: blur(14px)`, translucent `--bg` background, bottom hairline `--line`. Contents: the Slipreel wordmark with the app-icon glyph at left; anchor links `#features`, `#pricing`, `#faq`; a compact primary Download button at right. Below 720px, collapse the anchor links and keep only the wordmark and the button — do not build a hamburger menu.

- [ ] **Step 2: Build the hero markup**

The container element carries `data-cursor-stage`. The download anchor carries `data-download-link` **and a real fallback href**, so it works with JS disabled.

```html
<header class="hero" data-cursor-stage>
  <div class="container hero__inner">
    <p class="eyebrow">For macOS 13+ · Apple Silicon and Intel</p>
    <h1 class="hero__title">Screen recordings that look like they took a week.</h1>
    <p class="hero__sub">
      Slipreel auto-zooms, smooths your cursor, frames your app, and captions it —
      the moment you stop recording.
    </p>
    <div class="hero__cta">
      <a class="btn btn--primary"
         href="https://slipreel.app/download/Slipreel-1.0.1.dmg"
         data-download-link>Download for macOS</a>
      <a class="btn btn--ghost" href="#pricing">See pricing</a>
    </div>
    <p class="hero__meta"><span data-version-badge>Free download</span> · Signed and notarized by Apple</p>
    <figure class="hero__stage">
      <img src="assets/img/hero-editor.webp" width="1600" height="1000"
           alt="The Slipreel editor with a recording open, showing the zoom lane and audio waveform."
           fetchpriority="high" decoding="async">
    </figure>
  </div>
</header>
```

- [ ] **Step 3: Create the placeholder hero image**

Real screenshots arrive in Task 8. Generate a correctly-sized placeholder so layout and the lint are exercised now:

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
python3 -c "
import zlib, struct
w, h = 1600, 1000
row = b'\x00' + bytes([0x12, 0x12, 0x1C]) * w
raw = row * h
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 9))
       + chunk(b'IEND', b''))
open('/tmp/placeholder.png','wb').write(png)
"
cwebp -q 80 /tmp/placeholder.png -o site/assets/img/hero-editor.webp
```

- [ ] **Step 4: Style the hero**

Acceptance criteria:
- Title uses a fluid `clamp()` size, tops out around 76px desktop, never below 34px at 320px, with tight leading (~1.05) and slight negative letter-spacing.
- The product image sits in a rounded frame with a hairline `--line-strong` border, a long soft shadow, and a warm indigo glow beneath it (`--accent-glow`), so it reads as floating in light.
- On desktop the stage is partially cropped by the fold — enough of it visible to invite scrolling.
- Hero is legible at 320px with no horizontal scroll.

- [ ] **Step 5: Verify**

Run: `bash scripts/site-lint.sh`
Expected: `site-lint: clean`.

Then open the page and check it visually at 1440px and 375px widths:

```bash
python3 -m http.server 8765 --directory site
```

Visit `http://localhost:8765`. Confirm the acceptance criteria above, then stop the server.

- [ ] **Step 6: Commit**

```bash
git add site/index.html site/assets/css/site.css site/assets/img/hero-editor.webp
git commit -m "feat(site): sticky nav and hero"
```

---

### Task 4: Appcast-driven download button

**Files:**
- Create: `site/assets/js/appcast.js`, `site/assets/js/appcast.test.js`, `site/assets/js/site.js`
- Modify: `site/index.html`

**Interfaces:**
- Consumes: `[data-download-link]` and `[data-version-badge]` from Task 3.
- Produces: `site/assets/js/appcast.js` exporting `formatBytes(bytes) -> string|null`, `pickLatestItem(items) -> item|null`, `itemsFromDocument(doc) -> item[]`, where an item is `{ url: string|null, length: string|null, version: string|null, build: string|null }`.
- Produces: `site/assets/js/site.js` as the single `<script type="module">` entry point. Task 5 adds to this file.

- [ ] **Step 1: Write the failing tests**

Create `site/assets/js/appcast.test.js`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { formatBytes, pickLatestItem, itemsFromDocument } from './appcast.js';

test('formatBytes renders megabytes', () => {
  assert.equal(formatBytes(140703903), '141 MB');
});

test('formatBytes rejects junk', () => {
  assert.equal(formatBytes(0), null);
  assert.equal(formatBytes(-5), null);
  assert.equal(formatBytes('abc'), null);
  assert.equal(formatBytes(undefined), null);
});

test('pickLatestItem picks the highest build, not document order', () => {
  const items = [
    { url: 'a.dmg', build: '1000000' },
    { url: 'c.dmg', build: '1000002' },
    { url: 'b.dmg', build: '1000001' },
  ];
  assert.equal(pickLatestItem(items).url, 'c.dmg');
});

test('pickLatestItem ignores items with no url or no build', () => {
  const items = [
    { url: null, build: '9999999' },
    { url: 'real.dmg', build: '1000001' },
    { url: 'nobuild.dmg', build: null },
  ];
  assert.equal(pickLatestItem(items).url, 'real.dmg');
});

test('pickLatestItem returns null when nothing is usable', () => {
  assert.equal(pickLatestItem([]), null);
  assert.equal(pickLatestItem([{ url: null, build: null }]), null);
});

// Minimal stand-in for the parts of the DOM the parser touches.
function fakeDoc(items) {
  const el = (tag, text, attrs) => ({
    tagName: tag,
    textContent: text,
    getAttribute: (k) => (attrs && k in attrs ? attrs[k] : null),
  });
  const nodes = items.map((it) => {
    const kids = [];
    if (it.url !== undefined) {
      kids.push(el('enclosure', '', { url: it.url, length: it.length ?? null }));
    }
    if (it.version !== undefined) kids.push(el('sparkle:shortVersionString', it.version));
    if (it.build !== undefined) kids.push(el('sparkle:version', it.build));
    return {
      getElementsByTagName: (t) => kids.filter((k) => k.tagName === t),
    };
  });
  return { getElementsByTagName: (t) => (t === 'item' ? nodes : []) };
}

test('itemsFromDocument reads url, length, version and build', () => {
  const doc = fakeDoc([
    { url: 'https://slipreel.app/download/Slipreel-1.0.1.dmg', length: '140703903', version: '1.0.1', build: '1000001' },
  ]);
  assert.deepEqual(itemsFromDocument(doc), [
    { url: 'https://slipreel.app/download/Slipreel-1.0.1.dmg', length: '140703903', version: '1.0.1', build: '1000001' },
  ]);
});

test('itemsFromDocument tolerates a malformed item', () => {
  const doc = fakeDoc([{}]);
  assert.deepEqual(itemsFromDocument(doc), [
    { url: null, length: null, version: null, build: null },
  ]);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test site/assets/js/`
Expected: FAIL — `Cannot find module .../appcast.js`.

- [ ] **Step 3: Implement the parser**

Create `site/assets/js/appcast.js`:

```js
// Pure helpers for reading the Sparkle appcast that also drives in-app updates.
// Keeping these free of DOM construction makes them unit-testable under Node.

export function formatBytes(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n <= 0) return null;
  return `${Math.round(n / 1e6)} MB`;
}

export function pickLatestItem(items) {
  const usable = (items || []).filter(
    (i) => i && i.url && Number.isFinite(Number(i.build)) && i.build !== null,
  );
  if (usable.length === 0) return null;
  return usable.reduce((a, b) => (Number(b.build) > Number(a.build) ? b : a));
}

export function itemsFromDocument(doc) {
  const text = (el) => (el && el.textContent ? String(el.textContent).trim() : null);
  return Array.from(doc.getElementsByTagName('item')).map((item) => {
    const enc = item.getElementsByTagName('enclosure')[0];
    return {
      url: enc ? enc.getAttribute('url') : null,
      length: enc ? enc.getAttribute('length') : null,
      version: text(item.getElementsByTagName('sparkle:shortVersionString')[0]),
      build: text(item.getElementsByTagName('sparkle:version')[0]),
    };
  });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `node --test site/assets/js/`
Expected: `pass 7`, `fail 0`.

- [ ] **Step 5: Write the browser glue**

Create `site/assets/js/site.js`:

```js
import { itemsFromDocument, pickLatestItem, formatBytes } from './appcast.js';

document.documentElement.classList.add('js');

// The download button ships with a working href in the HTML. This only ever
// upgrades it to the newest release; a failure leaves the fallback in place.
async function hydrateDownload() {
  const link = document.querySelector('[data-download-link]');
  const badge = document.querySelector('[data-version-badge]');
  if (!link) return;
  try {
    const res = await fetch('/appcast.xml', { cache: 'no-cache' });
    if (!res.ok) return;
    const doc = new DOMParser().parseFromString(await res.text(), 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) return;
    const latest = pickLatestItem(itemsFromDocument(doc));
    if (!latest) return;
    link.href = latest.url;
    if (badge) {
      const size = formatBytes(latest.length);
      badge.textContent = ['Free download', latest.version && `v${latest.version}`, size]
        .filter(Boolean)
        .join(' · ');
    }
  } catch {
    /* keep the hardcoded fallback */
  }
}

hydrateDownload();
```

- [ ] **Step 6: Load the module**

Add before `</body>` in `site/index.html`:

```html
<script type="module" src="assets/js/site.js"></script>
```

- [ ] **Step 7: Verify in a browser against the live feed**

Run: `python3 -m http.server 8765 --directory site`

Because the page fetches the absolute path `/appcast.xml`, which does not exist on the local server, the button must **keep its fallback href** and the badge must still read `Free download`. Confirm no console errors, then stop the server.

Then confirm the live feed parses correctly:

```bash
curl -s https://slipreel.app/appcast.xml | node --input-type=module -e "
const xml = await new Response(process.stdin).text();
const m = [...xml.matchAll(/<enclosure url=\"([^\"]+)\"[^>]*length=\"(\d+)\"/g)];
console.log('newest enclosure:', m[0][1], m[0][2]);
"
```

Expected: prints the 1.0.1 DMG URL and its byte length, confirming the feed shape the parser expects.

- [ ] **Step 8: Run all tests and commit**

```bash
node --test site/assets/js/ && bash scripts/site-lint.sh
git add site/assets/js/appcast.js site/assets/js/appcast.test.js site/assets/js/site.js site/index.html
git commit -m "feat(site): drive download button and version badge from the appcast"
```

---

### Task 5: The theater, the scroll engine, and the cursor trail

The centerpiece. One app window stays pinned while the copy advances through five beats, and the page demonstrates Slipreel's own effects on the visitor.

**Files:**
- Modify: `site/index.html`, `site/assets/css/site.css`, `site/assets/js/site.js`
- Create: `site/assets/img/beat-{zoom,cursor,frames,keystrokes,captions}.webp` (placeholders)

**Interfaces:**
- Consumes: `[data-cursor-stage]` from Task 3; the module entry point from Task 4.
- Produces: `[data-theater]` wrapper, `[data-theater-visual]` pinned figure, `[data-beat="N"]` copy blocks (N = 0..4), `[data-beat-img="N"]` stacked images.

- [ ] **Step 1: Build the theater markup**

Five beats, in this order, with this copy:

| N | Heading | Body |
|---|---|---|
| 0 | Zooms that write themselves | Slipreel finds every click and pushes in on it — anticipating where your cursor is heading, not chasing it. Adjust any zoom on the timeline, or add your own. |
| 1 | A cursor that moves like it's on rails | Real cursors jitter. Slipreel smooths the path, adds motion blur, and highlights clicks — while keeping the timing honest, even through sped-up cuts. |
| 2 | Put it in a frame worth looking at | Drop your recording into a real device bezel, pick a wallpaper, set any aspect ratio. Preview matches export exactly. |
| 3 | Every keystroke, on the timeline | Slipreel records what you typed and renders it as an overlay you can edit — move it, trim it, delete the typo. |
| 4 | Captions, without the upload | Transcription runs on your Mac with a bundled Whisper model. Nothing is sent anywhere. Edit the text, burn it in on export. |

Structure: a tall `[data-theater]` section; inside it a `position: sticky; top: <nav height>` `[data-theater-visual]` figure holding five absolutely-stacked `[data-beat-img]` images; beside/below it five `[data-beat]` blocks that scroll past.

- [ ] **Step 2: Generate the five placeholder images**

Reuse the Task 3 placeholder recipe, writing to
`site/assets/img/beat-zoom.webp`, `beat-cursor.webp`, `beat-frames.webp`, `beat-keystrokes.webp`, `beat-captions.webp`.

- [ ] **Step 3: Implement the scroll engine**

Append to `site/assets/js/site.js`:

```js
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

// Beat switching: the beat whose copy block is nearest the viewport middle wins.
function mountTheater() {
  const theater = document.querySelector('[data-theater]');
  if (!theater) return;
  const beats = [...theater.querySelectorAll('[data-beat]')];
  const imgs = [...theater.querySelectorAll('[data-beat-img]')];
  if (!beats.length || !imgs.length) return;

  let active = -1;
  const setActive = (n) => {
    if (n === active) return;
    active = n;
    imgs.forEach((img) => img.classList.toggle('is-active', +img.dataset.beatImg === n));
    beats.forEach((b) => b.classList.toggle('is-active', +b.dataset.beat === n));
  };

  const io = new IntersectionObserver(
    (entries) => {
      const visible = entries.filter((e) => e.isIntersecting);
      if (!visible.length) return;
      const best = visible.reduce((a, b) => (b.intersectionRatio > a.intersectionRatio ? b : a));
      setActive(+best.target.dataset.beat);
    },
    { rootMargin: '-45% 0px -45% 0px', threshold: [0, 0.5, 1] },
  );
  beats.forEach((b) => io.observe(b));
  setActive(0);
}

// Reveal-on-scroll. Elements are visible by default in CSS; the `.js` class on
// <html> is what arms the hidden state, so a JS failure never hides content.
function mountReveals() {
  const items = [...document.querySelectorAll('.reveal')];
  if (!items.length) return;
  if (reduceMotion.matches) {
    items.forEach((el) => el.classList.add('is-revealed'));
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add('is-revealed');
          io.unobserve(e.target);
        }
      });
    },
    { rootMargin: '0px 0px -10% 0px', threshold: 0.15 },
  );
  items.forEach((el) => io.observe(el));
}

// Slipreel's signature smoothed cursor, performed on the visitor.
function mountCursorTrail() {
  const stage = document.querySelector('[data-cursor-stage]');
  if (!stage || reduceMotion.matches) return;
  if (!window.matchMedia('(pointer: fine)').matches) return;

  const canvas = document.createElement('canvas');
  canvas.className = 'cursor-trail';
  canvas.setAttribute('aria-hidden', 'true');
  stage.appendChild(canvas);
  const ctx = canvas.getContext('2d');

  let dpr = 1, w = 0, h = 0;
  const resize = () => {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    const r = stage.getBoundingClientRect();
    w = r.width; h = r.height;
    canvas.width = w * dpr; canvas.height = h * dpr;
    canvas.style.width = `${w}px`; canvas.style.height = `${h}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };
  resize();
  window.addEventListener('resize', resize, { passive: true });

  const trail = [];
  let target = null;
  // Critically damped follow, matching the app's spring feel.
  let px = 0, py = 0, has = false;

  stage.addEventListener('pointermove', (e) => {
    const r = stage.getBoundingClientRect();
    target = { x: e.clientX - r.left, y: e.clientY - r.top };
    if (!has) { px = target.x; py = target.y; has = true; }
  }, { passive: true });
  stage.addEventListener('pointerleave', () => { target = null; }, { passive: true });

  const tick = () => {
    ctx.clearRect(0, 0, w, h);
    if (target && has) {
      px += (target.x - px) * 0.18;
      py += (target.y - py) * 0.18;
      trail.push({ x: px, y: py });
      if (trail.length > 22) trail.shift();
    } else if (trail.length) {
      trail.shift();
    }
    for (let i = 0; i < trail.length; i++) {
      const p = trail[i];
      const t = i / trail.length;
      ctx.beginPath();
      ctx.arc(p.x, p.y, 3 + t * 7, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(108, 92, 231, ${t * t * 0.32})`;
      ctx.fill();
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

mountTheater();
mountReveals();
mountCursorTrail();
```

- [ ] **Step 4: Style the theater**

Acceptance criteria:
- The pinned figure stays visually centered while all five copy blocks scroll past it.
- Exactly one `[data-beat-img]` is at `opacity: 1` at a time; transitions are cross-fades of ~450ms with a slight scale, never a layout shift.
- Below 900px the layout stacks: each beat's copy sits directly above its own image, with **no pinning** (`position: static`).
- Under `prefers-reduced-motion: reduce`, pinning is disabled, all beats and images render stacked and visible, and the section still reads top-to-bottom in the correct order.
- The section is fully readable with JS disabled — beats visible, all five images visible.

- [ ] **Step 5: Style the cursor trail**

`.cursor-trail` is `position: absolute; inset: 0; pointer-events: none; z-index: 1;` inside the hero stage, sitting above the aurora but below the hero text.

- [ ] **Step 6: Verify**

Run: `python3 -m http.server 8765 --directory site`

Check, in order:
1. Moving the mouse in the hero paints a soft indigo trail that eases behind the pointer.
2. Scrolling the theater swaps images at the right beats.
3. In macOS System Settings enable Reduce Motion, reload, and confirm: no trail, no pinning, everything visible.
4. Disable JavaScript, reload, and confirm the page is fully readable.

Then stop the server.

- [ ] **Step 7: Run tests and commit**

```bash
node --test site/assets/js/ && bash scripts/site-lint.sh
git add site/index.html site/assets/css/site.css site/assets/js/site.js site/assets/img/
git commit -m "feat(site): pinned feature theater, reveal engine, cursor trail"
```

---

### Task 6: Deep dives, feature grid, and the Mac-app strip

**Files:**
- Modify: `site/index.html`, `site/assets/css/site.css`
- Create: `site/assets/img/deep-{timeline,audio,camera,export}.webp` (placeholders)

**Interfaces:**
- Consumes: `.reveal`, `.container`, `.section` from Task 2.
- Produces: the `#features` anchor target referenced by the nav.

- [ ] **Step 1: Build four alternating deep-dive sections**

Image left / copy right, alternating. Copy:

| Section | Heading | Body |
|---|---|---|
| Timeline | Cut it like an editor, not a toy | Split at the playhead with Cmd+K. Every slice keeps its own trim and speed, snapping to clicks and zoom edges as you cut. Waveforms render right in the slice. |
| Audio | Two tracks, mixed on your terms | Mic and system audio are captured as independent tracks. Set volume per track, mute either one, and Slipreel mixes them down on export. |
| Camera | Your face, in the corner, in sync | Record your webcam alongside the screen as its own track, kept frame-accurate against the recording. |
| Export | MP4 and GIF, exactly as previewed | The preview and the export run the same canvas math, so what you approve is what ships. Pick an aspect ratio and go. |

- [ ] **Step 2: Build the feature grid**

Heading: "And the hundred small things." A responsive grid of 16 items, each a short label plus one line. Use exactly these, all verified in the codebase:

3-2-1 countdown · Pause and resume · Global hotkeys · Full display, window, or region · Auto-zoom detection · Manual zoom placement · 3D tilt · Zoom movements · Device frames · Wallpapers and solid colors · Six aspect ratios · Per-slice speed · Cursor smoothing presets · Crash recovery · Duration warnings · Automatic updates

- [ ] **Step 3: Build the "Built like a Mac app" strip**

Four short claims, each one line, all verifiable:
- Native capture via ScreenCaptureKit — no screen-scraping hacks.
- Captions transcribe on-device. Your recordings never leave your Mac.
- Signed and notarized by Apple, distributed direct.
- Updates arrive in the app, signed and verified.

- [ ] **Step 4: Generate placeholder images and verify**

Reuse the Task 3 recipe for the four `deep-*.webp` files.

Run: `bash scripts/site-lint.sh`
Expected: `site-lint: clean`.

Acceptance criteria:
- Deep-dive sections stack to a single column below 900px with the image first.
- The grid is 4 columns at desktop, 2 at tablet, 1 at mobile.
- Every claim on the page traces to a real feature.

- [ ] **Step 5: Commit**

```bash
git add site/index.html site/assets/css/site.css site/assets/img/
git commit -m "feat(site): feature deep dives, grid, and platform strip"
```

---

### Task 7: Pricing, FAQ, and footer

**Files:**
- Modify: `site/index.html`, `site/assets/css/site.css`

**Interfaces:**
- Produces: the `#pricing` and `#faq` anchor targets referenced by the nav.

- [ ] **Step 1: Build the pricing section**

An early-access banner above two cards:

> **Early access.** Slipreel is shipping and updating weekly. Buy now at founding pricing and your license key arrives the moment licensing lands — the app is free to download and use in the meantime.

Two cards, lifetime marked as the recommended one:

**Yearly — $79/year.** Every update while subscribed · All features · macOS 13+ · Cancel anytime. Button: "Get Slipreel yearly" → `href="#stripe-yearly"`.

**Lifetime — $149 once.** Yours permanently · One year of updates included · All features · macOS 13+. Button: "Get Slipreel for life" → `href="#stripe-lifetime"`.

Below both: "Prefer to try it first? Download Slipreel free — no account, no time limit." linking to the download.

Add an HTML comment above each button:

```html
<!-- TODO: replace with the real Stripe payment link -->
```

- [ ] **Step 2: Build the FAQ**

Native `<details>`/`<summary>` — keyboard accessible with zero JS. Nine entries:

1. **What does "early access" mean?** Slipreel is complete and in daily use, but license-key delivery is not built yet. Buying now locks in founding pricing; your key arrives when licensing ships. The app is free to download and fully functional today.
2. **What happens after the first year on a lifetime license?** The app keeps working forever, and every version released in your first year stays yours. Updates after that are a separate, optional renewal.
3. **What do I need to run it?** macOS 13 or later, on Apple Silicon or Intel.
4. **Do my recordings get uploaded anywhere?** No. Recording, editing, captions, and export all run on your Mac. Slipreel has no account system and no server.
5. **How do captions work offline?** A Whisper speech model ships inside the app and runs locally.
6. **Is it safe to install?** Slipreel is signed with an Apple Developer ID and notarized by Apple. Updates are cryptographically verified before they install.
7. **Can I edit the automatic zooms?** Yes. Every auto-detected zoom is a normal timeline region you can move, resize, retime, or delete, and you can add your own.
8. **Does it record system audio?** Yes, as its own track, separate from the microphone, so you can mix them independently.
9. **Can I get a refund?** Email `hello@slipreel.app` within 14 days and you will get your money back.

- [ ] **Step 3: Build the final CTA and footer**

Final CTA: a centered band repeating the headline promise with the download button (also carrying `data-download-link` — Task 4's hydration uses `querySelector`, so update `site.js` to `querySelectorAll` and set the href on every match).

Update the `hydrateDownload` function in `site/assets/js/site.js`:

```js
async function hydrateDownload() {
  const links = [...document.querySelectorAll('[data-download-link]')];
  const badge = document.querySelector('[data-version-badge]');
  if (!links.length) return;
  try {
    const res = await fetch('/appcast.xml', { cache: 'no-cache' });
    if (!res.ok) return;
    const doc = new DOMParser().parseFromString(await res.text(), 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) return;
    const latest = pickLatestItem(itemsFromDocument(doc));
    if (!latest) return;
    links.forEach((link) => { link.href = latest.url; });
    if (badge) {
      const size = formatBytes(latest.length);
      badge.textContent = ['Free download', latest.version && `v${latest.version}`, size]
        .filter(Boolean)
        .join(' · ');
    }
  } catch {
    /* keep the hardcoded fallback */
  }
}
```

Footer: wordmark, `hello@slipreel.app` as a `mailto:` link, and `© 2026 Becoming Ventures, LLC`. No social links.

- [ ] **Step 4: Verify**

```bash
node --test site/assets/js/ && bash scripts/site-lint.sh
```

Acceptance criteria:
- Pricing cards stack on mobile with the recommended card first.
- FAQ opens and closes with keyboard alone.
- Both download buttons carry the fallback href in the HTML.

- [ ] **Step 5: Commit**

```bash
git add site/index.html site/assets/css/site.css site/assets/js/site.js
git commit -m "feat(site): pricing, FAQ, and footer"
```

---

### Task 8: Real product screenshots

**Run this task in the main session, not a subagent** — it needs interactive screen-recording permission and a decision about what is safe to have on screen.

**Files:**
- Replace: every `site/assets/img/*.webp` placeholder
- Modify: `site/index.html` (alt text to match what each image actually shows)

- [ ] **Step 1: Agree on capture content with the user**

Confirm what to record. The recording must contain nothing private. A neutral, visually rich target works best — a code editor with a sample project, or a simple web app.

- [ ] **Step 2: Capture**

Launch `/Applications/Slipreel.app` (v1.0.1). Make a short recording of the agreed target, open it in the editor, and set up a state worth photographing: a wallpaper applied, at least two zoom regions on the lane, a visible audio waveform, and the timeline zoomed enough to show slice detail.

Capture full-window screenshots of: the editor with the timeline, the zoom placement picker, a device frame applied, the keystroke lane, and the captions editor.

- [ ] **Step 3: Process**

Crop each to the app window, resize the long edge to 1600px, and convert:

```bash
cwebp -q 82 <source>.png -o site/assets/img/<name>.webp
```

Verify each is under 250 KB:

```bash
ls -lh site/assets/img/
```

- [ ] **Step 4: Update alt text**

Every `alt` must describe what the image actually shows now, not the placeholder.

- [ ] **Step 5: Verify and commit**

```bash
bash scripts/site-lint.sh
git add site/assets/img/ site/index.html
git commit -m "feat(site): real product screenshots"
```

---

### Task 9: Metadata, accessibility pass, and production deploy

**Files:**
- Modify: `site/index.html`, `site/assets/css/site.css`
- Create: `site/assets/img/og.webp`, `site/favicon.png`, `site/assets/img/og.png`

**Interfaces:**
- Consumes: everything.

- [ ] **Step 1: Export the favicon and OG image from the app icon**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
sips -z 180 180 packages/screen_recorder/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png \
  --out site/favicon.png
```

Compose a 1200x630 Open Graph image: the dark canvas, the aurora, the wordmark, the headline, and the hero screenshot. Save as `site/assets/img/og.png` (PNG — several social scrapers still do not handle WebP).

- [ ] **Step 2: Add head metadata**

```html
<title>Slipreel — screen recordings that look like they took a week</title>
<meta name="description" content="Slipreel is a macOS screen recorder that auto-zooms, smooths your cursor, frames your app, and captions it — the moment you stop recording.">
<link rel="icon" href="favicon.png" sizes="any">
<meta property="og:type" content="website">
<meta property="og:url" content="https://slipreel.app/">
<meta property="og:title" content="Slipreel — screen recordings that look like they took a week">
<meta property="og:description" content="Auto-zoom, smoothed cursor, device frames, on-device captions. A macOS screen recorder and editor.">
<meta property="og:image" content="https://slipreel.app/assets/img/og.png">
<meta name="twitter:card" content="summary_large_image">
```

- [ ] **Step 3: Add JSON-LD**

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Slipreel",
  "applicationCategory": "MultimediaApplication",
  "operatingSystem": "macOS 13.0 or later",
  "url": "https://slipreel.app/",
  "downloadUrl": "https://slipreel.app/download/",
  "offers": [
    { "@type": "Offer", "price": "79.00", "priceCurrency": "USD", "name": "Yearly" },
    { "@type": "Offer", "price": "149.00", "priceCurrency": "USD", "name": "Lifetime" }
  ],
  "publisher": { "@type": "Organization", "name": "Becoming Ventures, LLC" }
}
</script>
```

- [ ] **Step 4: Accessibility pass**

Walk the whole page and confirm:
- One `<h1>`; heading levels never skip.
- `<nav>`, `<main>`, `<footer>` landmarks present; a skip link to `#main` is the first focusable element.
- Every image has meaningful `alt`; decorative layers carry `aria-hidden="true"`.
- Tab through the entire page: every interactive element has a visible focus ring and a sensible order.
- Body text and both `--ink` and `--ink-dim` pass WCAG AA against `--bg`.

- [ ] **Step 5: Full verification**

```bash
node --test site/assets/js/
bash scripts/site-lint.sh
bash scripts/deploy-site.test.sh
bash scripts/site-lint.test.sh
```

Expected: all pass.

- [ ] **Step 6: Record the pre-deploy artifact state**

```bash
ssh trader-vps 'md5sum /var/www/slipreel/appcast.xml; ls -1 /var/www/slipreel/download/'
```

- [ ] **Step 7: Deploy**

```bash
bash scripts/deploy-site.sh
```

- [ ] **Step 8: Verify production**

```bash
curl -sS -o /dev/null -w 'site: %{http_code}\n' https://slipreel.app/
curl -sS -o /dev/null -w 'appcast: %{http_code}\n' https://slipreel.app/appcast.xml
curl -sS -o /dev/null -w 'dmg: %{http_code}\n' -r 0-1023 https://slipreel.app/download/Slipreel-1.0.1.dmg
ssh trader-vps 'md5sum /var/www/slipreel/appcast.xml; ls -1 /var/www/slipreel/download/'
```

Expected: three `200`s (the DMG range request may return `206`), and the appcast md5 plus DMG listing **identical to Step 6**.

Then load `https://slipreel.app/` in a browser and confirm the download button points at the newest DMG and the badge shows the version and size.

- [ ] **Step 9: Commit**

```bash
git add site/ scripts/
git commit -m "feat(site): metadata, accessibility pass, production deploy"
```

---

## Self-review notes

**Spec coverage.** Every spec section maps to a task: page architecture → 3, 5, 6, 7; visual system → 2; signature interactions → 5; download behaviour → 4; technical structure → 1; screenshots → 8; SEO and accessibility → 9; constraints → enforced continuously by `scripts/site-lint.sh` from Task 2 onward.

**Known deviation.** Task 7 revises `hydrateDownload` from Task 4 (`querySelector` → `querySelectorAll`) because the final CTA introduces a second download button. The full replacement function is given inline rather than as a diff, since the implementer may read tasks out of order.

**Deferred by design.** Real Stripe links, Cloudflare Email Routing for `hello@slipreel.app`, and licence-key delivery are all out of scope and flagged in the spec.
