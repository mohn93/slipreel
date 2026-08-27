# Web-Flow Pages Implementation Plan (Phase 4b)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the static web pages on `slipreel.app` that drive the purchase → login → app-unlock flow: a pricing page that starts Stripe Checkout, a success page that logs the buyer in and deep-links the app, a login page (magic-link) for re-activation, and an account page (manage billing + devices) — all calling the Phase-4a API at `api.slipreel.app` with credentials.

**Architecture:** Plain HTML + vanilla ES-module JS in `site/` (no build step), matching the existing hand-written marketing site and its design system (`assets/css/site.css`). All non-trivial logic lives in DOM-free modules (`assets/js/api.js`, `assets/js/flow.js`, `assets/js/config.js`) unit-tested with Node's built-in test runner (`node --test`), the convention already used by `assets/js/appcast.js`. Each page is a thin HTML shell + a small glue script that reads URL/form inputs, calls a flow function, and performs the returned action (redirect / render / open `slipreel://`). The app-unlock handoff mints a device token via `POST /v1/token` (after the session cookie is set by checkout or magic-link) and navigates to `slipreel://auth?...` with a visible manual fallback. Clean URLs (`/pricing`, `/login`, `/account`, `/success`) are served by an nginx `try_files` rule.

**Tech Stack:** Static HTML + vanilla ES modules (browsers), `node --test` for the logic modules (no new deps), the existing `assets/css/site.css` design system, nginx (clean URLs), the existing rsync deploy pipeline.

**Spec:** [docs/superpowers/specs/2026-08-26-stripe-licensing-design.md](../specs/2026-08-26-stripe-licensing-design.md) (§8 auth flow, §10 web pages)

**Builds on:** Phase 4a (branch `feat/stripe-licensing`, PR #65) — the API endpoints these pages consume already exist and are tested. This plan adds only frontend + deploy config; it touches no `server/` code.

## Global Constraints

- **Location:** all page/JS/CSS work under `site/`; nginx/deploy under `server/deploy/` + `scripts/`. No `server/` app code changes.
- **No build step:** plain HTML + native ES modules (`<script type="module">`), matching the existing site. No bundler, no framework.
- **Testable logic is DOM-free:** `api.js`/`flow.js`/`config.js` are pure modules (take a `fetch`/`api`/`location` as args) tested with `node --test`, exactly like `assets/js/appcast.js`. Page glue (DOM wiring) is thin and browser-verified, not unit-tested.
- **Credentials:** every API call uses `fetch(..., { credentials: 'include' })` so the session cookie flows (same-site `slipreel.app` ↔ `api.slipreel.app`).
- **Design:** reuse `assets/css/site.css` tokens/classes (`.container`, `.btn`, `.btn--primary`, `.nav`, `.site-footer`, CSS vars `--accent`/`--bg-card`/`--radius`) and the nav/footer markup from `index.html` for visual consistency. New page-specific styles go in `assets/css/app.css`.
- **Deep link:** `slipreel://auth?token=<jwt>&refresh=<rt>&device_id=<dev>&state=<nonce>` (only include params that exist). Always show a visible manual "Open Slipreel" fallback (custom-scheme auto-navigation can be blocked).
- **API base:** `https://api.slipreel.app` in production (hostname `slipreel.app`); overridable for local dev via a `<meta name="slipreel-api-base">` tag or the dev default `http://<host>:8080`.
- **No secrets client-side:** pages hold no keys. Stripe Checkout is hosted (redirect); the only tokens the browser sees are the entitlement token + refresh token during the one-time deep-link handoff.
- **Git:** branch `feat/stripe-licensing`. Stage only files you created/changed.

## Notes / out of scope

- The API needs `CORS_ORIGINS` to include the browser origin. For local dev, boot the server with `CORS_ORIGINS=http://localhost:4173` (or your static-server origin) plus Stripe test keys + entitlement keys to exercise the full flow; without them, pages render but live calls fail (documented in Task 7).
- The existing `index.html` marketing pricing (JSON-LD: Yearly $79 / **Lifetime $149**) does not match the Stripe test prices (monthly $9 / yearly $79 / **one-time $99**). Reconciling the landing-page pricing copy + wiring its CTAs to `/pricing` is called out in Task 7 as a follow-up, not built here.
- Server-side `state` validation stays deferred to Phase 5 (the app generates the nonce and verifies the echo). These pages only pass `state` through.

---

## File Structure

```
site/
  package.json          # + "test": "node --test"
  assets/
    js/
      config.js         # apiBase(hostname, metaContent) — pure
      api.js            # createApi(baseUrl, fetchImpl) — the API client
      flow.js           # startCheckout/completeCheckout/completeMagicLink/requestMagicLink/buildDeeplink
      config.test.js
      api.test.js
      flow.test.js
      page-pricing.js   # glue
      page-success.js   # glue
      page-login.js     # glue
      page-account.js   # glue
    css/
      app.css           # forms, cards, device list, status banners
  pricing.html
  success.html
  cancel.html
  login.html
  account.html
server/deploy/
  nginx-site.conf       # NEW: static site + clean-URL try_files (slipreel.app)
scripts/
  deploy-site.sh        # (unchanged behavior; ensure new files ship — they do, rsync copies site/)
README or docs note      # dev/run instructions (in this plan's Task 7 + server README already covers CORS)
```

Note: the marketing `index.html`, `favicon*`, `assets/css/site.css`, and `assets/js/site.js` already exist and are unchanged except where Task 7 optionally wires CTAs (out of scope here).

---

### Task 1: API base config + API client (`config.js`, `api.js`)

Pure modules with `node --test`. Deliverable: tests prove `apiBase` picks prod vs dev, and `createApi` issues credentialed requests with the right method/path/body.

**Files:**
- Modify: `site/package.json` (add a `test` script)
- Create: `site/assets/js/config.js`
- Create: `site/assets/js/api.js`
- Create: `site/assets/js/config.test.js`
- Create: `site/assets/js/api.test.js`

**Interfaces:**
- Produces:
  - `function apiBase(hostname: string, metaContent?: string | null): string`
  - `function createApi(baseUrl: string, fetchImpl = fetch)` → `{ checkout, sessionFromCheckout, token, magicLink, magicLinkVerify, portal, devices, deleteDevice, logout }`, each returning `Promise<{ ok: boolean; status: number; data: any }>`.

- [ ] **Step 1: Add a test script** — set `site/package.json` to:

```json
{
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test"
  }
}
```

- [ ] **Step 2: Write the failing test `site/assets/js/config.test.js`**

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { apiBase } from './config.js';

test('apiBase uses the API subdomain in production', () => {
  assert.equal(apiBase('slipreel.app'), 'https://api.slipreel.app');
  assert.equal(apiBase('www.slipreel.app'), 'https://api.slipreel.app');
});

test('apiBase honors an explicit meta override', () => {
  assert.equal(apiBase('localhost', 'http://localhost:8080'), 'http://localhost:8080');
});

test('apiBase falls back to host:8080 in dev', () => {
  assert.equal(apiBase('localhost'), 'http://localhost:8080');
  assert.equal(apiBase('127.0.0.1'), 'http://127.0.0.1:8080');
});
```

- [ ] **Step 3: Run it — expect FAIL**

Run: `node --test site/assets/js/config.test.js`
Expected: FAIL (cannot import `./config.js`).

- [ ] **Step 4: Implement `site/assets/js/config.js`**

```js
// Resolve the API base URL. Pure (no DOM) so it is unit-testable under node:test.
// Production: the api. subdomain. Dev: an explicit <meta> override, else host:8080.
export function apiBase(hostname, metaContent) {
  if (hostname === 'slipreel.app' || hostname === 'www.slipreel.app') {
    return 'https://api.slipreel.app';
  }
  if (metaContent) return metaContent;
  return `http://${hostname}:8080`;
}
```

- [ ] **Step 5: Run it — expect PASS (3 tests)**

Run: `node --test site/assets/js/config.test.js`

- [ ] **Step 6: Write the failing test `site/assets/js/api.test.js`**

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { createApi } from './api.js';

function fakeFetch(record, response = { ok: true, status: 200, body: { url: 'u' } }) {
  return async (url, init) => {
    record.url = url; record.init = init;
    return {
      ok: response.ok, status: response.status,
      json: async () => response.body,
    };
  };
}

test('checkout POSTs JSON with credentials', async () => {
  const rec = {};
  const api = createApi('https://api.slipreel.app', fakeFetch(rec));
  const r = await api.checkout({ email: 'a@b.com', plan: 'yearly' });
  assert.equal(rec.url, 'https://api.slipreel.app/v1/checkout');
  assert.equal(rec.init.method, 'POST');
  assert.equal(rec.init.credentials, 'include');
  assert.equal(rec.init.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(rec.init.body), { email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { ok: true, status: 200, data: { url: 'u' } });
});

test('sessionFromCheckout wraps the id', async () => {
  const rec = {};
  const api = createApi('https://x', fakeFetch(rec, { ok: true, status: 200, body: { user: {} } }));
  await api.sessionFromCheckout('cs_1');
  assert.equal(rec.url, 'https://x/v1/auth/session-from-checkout');
  assert.deepEqual(JSON.parse(rec.init.body), { checkout_session_id: 'cs_1' });
});

test('devices is a credentialed GET with no body', async () => {
  const rec = {};
  const api = createApi('https://x', fakeFetch(rec, { ok: true, status: 200, body: { devices: [] } }));
  await api.devices();
  assert.equal(rec.url, 'https://x/v1/devices');
  assert.equal(rec.init.method, 'GET');
  assert.equal(rec.init.credentials, 'include');
  assert.equal(rec.init.body, undefined);
});

test('deleteDevice encodes the id in the path', async () => {
  const rec = {};
  const api = createApi('https://x', fakeFetch(rec, { ok: true, status: 200, body: { ok: true } }));
  await api.deleteDevice('dev_a b');
  assert.equal(rec.url, 'https://x/v1/devices/dev_a%20b');
  assert.equal(rec.init.method, 'DELETE');
});

test('non-2xx and non-JSON bodies surface as {ok:false} with null data', async () => {
  const api = createApi('https://x', async () => ({
    ok: false, status: 409, json: async () => { throw new Error('no json'); },
  }));
  const r = await api.token({ fingerprint: 'fp' });
  assert.equal(r.ok, false); assert.equal(r.status, 409); assert.equal(r.data, null);
});
```

- [ ] **Step 7: Run it — expect FAIL**

Run: `node --test site/assets/js/api.test.js`

- [ ] **Step 8: Implement `site/assets/js/api.js`**

```js
// Thin API client. `fetchImpl` is injectable so it is testable under node:test.
// Every call sends the session cookie (credentials:'include').
export function createApi(baseUrl, fetchImpl = fetch) {
  async function call(method, path, body) {
    const res = await fetchImpl(baseUrl + path, {
      method,
      credentials: 'include',
      headers: body ? { 'Content-Type': 'application/json' } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    let data = null;
    try { data = await res.json(); } catch { data = null; }
    return { ok: res.ok, status: res.status, data };
  }
  return {
    checkout: (b) => call('POST', '/v1/checkout', b),
    sessionFromCheckout: (id) => call('POST', '/v1/auth/session-from-checkout', { checkout_session_id: id }),
    token: (b) => call('POST', '/v1/token', b),
    magicLink: (b) => call('POST', '/v1/auth/magic-link', b),
    magicLinkVerify: (token) => call('POST', '/v1/auth/magic-link/verify', { token }),
    portal: (email) => call('POST', '/v1/portal', { email }),
    devices: () => call('GET', '/v1/devices'),
    deleteDevice: (id) => call('DELETE', '/v1/devices/' + encodeURIComponent(id)),
    logout: () => call('POST', '/v1/auth/logout'),
  };
}
```

- [ ] **Step 9: Run all site tests — expect PASS**

Run: `npm --prefix site test`
Expected: config + api tests pass (and the pre-existing `appcast.test.js` still passes).

- [ ] **Step 10: Commit**

```bash
git add site/package.json site/assets/js/config.js site/assets/js/api.js \
  site/assets/js/config.test.js site/assets/js/api.test.js
git commit -m "feat(site): API base config and credentialed API client"
```

---

### Task 2: Flow orchestration (`flow.js`)

DOM-free functions that sequence the API calls and return an action descriptor for the page to perform. Deliverable: `node --test` proves checkout, the checkout→(deeplink|account) branch, the magic-link branch, the seat-limit branch, and the deep-link URL format.

**Files:**
- Create: `site/assets/js/flow.js`
- Create: `site/assets/js/flow.test.js`

**Interfaces:**
- Consumes: an `api` object shaped like `createApi(...)`'s return.
- Produces:
  - `function buildDeeplink({ token, refresh_token, device_id, state }): string`
  - `async function startCheckout(api, { email, plan, device?, deviceName?, state? })` → `{ redirect } | { error, status }`
  - `async function completeCheckout(api, sessionId)` → `{ deeplink } | { account: { email } } | { seatLimit: [...] } | { error, status }`
  - `async function completeMagicLink(api, token)` → same shape as completeCheckout
  - `async function requestMagicLink(api, { email, device?, deviceName?, state? })` → `{ sent: boolean }`

- [ ] **Step 1: Write the failing test `site/assets/js/flow.test.js`**

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { buildDeeplink, startCheckout, completeCheckout, completeMagicLink, requestMagicLink } from './flow.js';

const okToken = { ok: true, status: 200, data: { token: 'jwt', refresh_token: 'rt', device_id: 'dev_1' } };

function apiStub(overrides = {}) {
  return {
    checkout: async () => ({ ok: true, status: 200, data: { url: 'https://checkout.stripe/x' } }),
    sessionFromCheckout: async () => ({ ok: true, status: 200, data: { user: { email: 'u@e.com' }, device: null, device_name: null, state: null } }),
    token: async () => okToken,
    magicLinkVerify: async () => ({ ok: true, status: 200, data: { user: { email: 'u@e.com' }, device: null, device_name: null, state: null } }),
    magicLink: async () => ({ ok: true, status: 200, data: { sent: true } }),
    ...overrides,
  };
}

test('buildDeeplink includes only present params', () => {
  assert.equal(buildDeeplink({ token: 'jwt' }), 'slipreel://auth?token=jwt');
  assert.equal(
    buildDeeplink({ token: 'j', refresh_token: 'r', device_id: 'd', state: 'n' }),
    'slipreel://auth?token=j&refresh=r&device_id=d&state=n',
  );
});

test('startCheckout returns the redirect url', async () => {
  const r = await startCheckout(apiStub(), { email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { redirect: 'https://checkout.stripe/x' });
});

test('startCheckout surfaces an error', async () => {
  const api = apiStub({ checkout: async () => ({ ok: false, status: 400, data: { error: 'bad' } }) });
  const r = await startCheckout(api, { email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { error: 'bad', status: 400 });
});

test('completeCheckout with a device mints a token and returns a deeplink', async () => {
  const api = apiStub({
    sessionFromCheckout: async () => ({ ok: true, status: 200, data: { user: {}, device: 'fp-1', device_name: 'Mac', state: 'n' } }),
  });
  const r = await completeCheckout(api, 'cs_1');
  assert.equal(r.deeplink, 'slipreel://auth?token=jwt&refresh=rt&device_id=dev_1&state=n');
});

test('completeCheckout without a device routes to account', async () => {
  const r = await completeCheckout(apiStub(), 'cs_1');
  assert.deepEqual(r, { account: { email: 'u@e.com' } });
});

test('completeCheckout surfaces a seat-limit 409', async () => {
  const api = apiStub({
    sessionFromCheckout: async () => ({ ok: true, status: 200, data: { user: {}, device: 'fp-9', device_name: null, state: null } }),
    token: async () => ({ ok: false, status: 409, data: { error: 'seat_limit', devices: [{ id: 'd1' }, { id: 'd2' }] } }),
  });
  const r = await completeCheckout(api, 'cs_1');
  assert.deepEqual(r, { seatLimit: [{ id: 'd1' }, { id: 'd2' }] });
});

test('completeMagicLink mirrors completeCheckout (device -> deeplink)', async () => {
  const api = apiStub({
    magicLinkVerify: async () => ({ ok: true, status: 200, data: { user: {}, device: 'fp-2', device_name: 'Air', state: 's' } }),
  });
  const r = await completeMagicLink(api, 'mtok');
  assert.equal(r.deeplink, 'slipreel://auth?token=jwt&refresh=rt&device_id=dev_1&state=s');
});

test('requestMagicLink reports sent', async () => {
  assert.deepEqual(await requestMagicLink(apiStub(), { email: 'a@b.com' }), { sent: true });
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `node --test site/assets/js/flow.test.js`

- [ ] **Step 3: Implement `site/assets/js/flow.js`**

```js
export function buildDeeplink({ token, refresh_token, device_id, state }) {
  const p = new URLSearchParams();
  p.set('token', token);
  if (refresh_token) p.set('refresh', refresh_token);
  if (device_id) p.set('device_id', device_id);
  if (state) p.set('state', state);
  return 'slipreel://auth?' + p.toString();
}

export async function startCheckout(api, { email, plan, device, deviceName, state }) {
  const body = { email, plan };
  if (device) body.device = device;
  if (deviceName) body.device_name = deviceName;
  if (state) body.state = state;
  const r = await api.checkout(body);
  if (!r.ok) return { error: r.data?.error || 'checkout_failed', status: r.status };
  return { redirect: r.data.url };
}

// After a session cookie is established, either mint a device token and deep-link
// the app (app-initiated flow, `device` present) or route to the account page.
async function afterSession(api, ctx) {
  if (ctx.device) {
    const t = await api.token({ fingerprint: ctx.device, device_name: ctx.device_name || null });
    if (t.status === 409) return { seatLimit: t.data?.devices || [] };
    if (!t.ok) return { error: t.data?.error || 'token_failed', status: t.status };
    return { deeplink: buildDeeplink({ ...t.data, state: ctx.state }) };
  }
  return { account: { email: ctx.email } };
}

export async function completeCheckout(api, sessionId) {
  const s = await api.sessionFromCheckout(sessionId);
  if (!s.ok) return { error: s.data?.error || 'session_failed', status: s.status };
  return afterSession(api, {
    device: s.data.device, device_name: s.data.device_name, state: s.data.state,
    email: s.data.user?.email,
  });
}

export async function completeMagicLink(api, token) {
  const v = await api.magicLinkVerify(token);
  if (!v.ok) return { error: v.data?.error || 'verify_failed', status: v.status };
  return afterSession(api, {
    device: v.data.device, device_name: v.data.device_name, state: v.data.state,
    email: v.data.user?.email,
  });
}

export async function requestMagicLink(api, { email, device, deviceName, state }) {
  const body = { email };
  if (device) body.device = device;
  if (deviceName) body.device_name = deviceName;
  if (state) body.state = state;
  const r = await api.magicLink(body);
  return { sent: r.ok };
}
```

- [ ] **Step 4: Run it — expect PASS (all cases)**

Run: `node --test site/assets/js/flow.test.js`

- [ ] **Step 5: Full site test run, then commit**

Run: `npm --prefix site test`

```bash
git add site/assets/js/flow.js site/assets/js/flow.test.js
git commit -m "feat(site): checkout/magic-link/deeplink flow orchestration"
```

---

### Task 3: Shared page styles + pricing page

Adds `app.css` and the first page. Deliverable: `/pricing` renders (matching the site design), reads `device`/`state` from the URL, and starting checkout redirects to Stripe. Verified in the browser (render + no console errors + the checkout call fires).

**Files:**
- Create: `site/assets/css/app.css`
- Create: `site/pricing.html`
- Create: `site/assets/js/page-pricing.js`

**Interfaces:** consumes `apiBase` (config.js), `createApi` (api.js), `startCheckout` (flow.js).

- [ ] **Step 1: Create `site/assets/css/app.css`** — page-specific styles layered on `site.css` tokens.

```css
/* Flow pages: forms, cards, device rows, status banners. Uses site.css tokens. */
.flow { max-width: 560px; margin: 0 auto; padding: 96px 20px 80px; }
.flow__title { font-size: clamp(1.6rem, 4vw, 2.2rem); margin: 0 0 8px; }
.flow__sub { color: var(--ink-dim); margin: 0 0 28px; }
.card { background: var(--bg-card); border: 1px solid rgba(255,255,255,.08);
  border-radius: var(--radius-lg); padding: 22px; margin-bottom: 16px; }
.field { display: block; margin: 0 0 14px; }
.field__label { display: block; font-size: .85rem; color: var(--ink-dim); margin-bottom: 6px; }
.input { width: 100%; padding: 12px 14px; border-radius: var(--radius);
  border: 1px solid rgba(255,255,255,.14); background: var(--bg-elev); color: inherit;
  font: inherit; }
.input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
.plans { display: grid; gap: 12px; margin-top: 8px; }
.plan { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
.plan__price { font-weight: 600; }
.status { padding: 12px 14px; border-radius: var(--radius); margin-top: 16px; font-size: .95rem; }
.status--err { background: rgba(255,80,80,.12); border: 1px solid rgba(255,80,80,.3); }
.status--ok { background: rgba(90,200,120,.12); border: 1px solid rgba(90,200,120,.3); }
.device-row { display: flex; justify-content: space-between; align-items: center;
  padding: 12px 0; border-bottom: 1px solid rgba(255,255,255,.07); }
.muted { color: var(--ink-dim); font-size: .85rem; }
.btn--block { width: 100%; justify-content: center; }
.hidden { display: none; }
```

- [ ] **Step 2: Create `site/pricing.html`** — shell reusing site.css + nav/footer, with the plan buttons.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Slipreel — Pricing</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/css/site.css">
<link rel="stylesheet" href="assets/css/app.css">
</head>
<body>
<main class="flow">
  <h1 class="flow__title">Unlock export</h1>
  <p class="flow__sub">Record, edit, and preview are free. Export needs Slipreel Pro.</p>

  <div class="card">
    <label class="field">
      <span class="field__label">Email</span>
      <input class="input" id="email" type="email" autocomplete="email" placeholder="you@example.com" required>
    </label>
    <div class="plans">
      <button class="btn btn--primary plan" data-plan="monthly"><span>Monthly</span><span class="plan__price">$9 / mo</span></button>
      <button class="btn btn--primary plan" data-plan="yearly"><span>Yearly</span><span class="plan__price">$79 / yr</span></button>
      <button class="btn btn--primary plan" data-plan="onetime"><span>One-time</span><span class="plan__price">$99</span></button>
    </div>
    <div class="status hidden" id="status" role="alert"></div>
  </div>
  <p class="muted">Secure checkout by Stripe. One-time includes 1 year of updates.</p>
</main>
<script type="module" src="assets/js/page-pricing.js"></script>
</body>
</html>
```

- [ ] **Step 3: Create `site/assets/js/page-pricing.js`** — glue.

```js
import { apiBase } from './config.js';
import { createApi } from './api.js';
import { startCheckout } from './flow.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const params = new URLSearchParams(location.search);
const device = params.get('device');
const state = params.get('state');
const deviceName = params.get('device_name');

const statusEl = document.getElementById('status');
function showError(msg) {
  statusEl.textContent = msg;
  statusEl.className = 'status status--err';
}

for (const btn of document.querySelectorAll('.plan')) {
  btn.addEventListener('click', async () => {
    const email = /** @type {HTMLInputElement} */ (document.getElementById('email')).value.trim();
    if (!email) return showError('Enter your email first.');
    statusEl.className = 'status hidden';
    for (const b of document.querySelectorAll('.plan')) b.setAttribute('disabled', 'true');
    const r = await startCheckout(api, { email, plan: btn.dataset.plan, device, deviceName, state });
    if (r.redirect) { location.href = r.redirect; return; }
    for (const b of document.querySelectorAll('.plan')) b.removeAttribute('disabled');
    showError(r.error === 'checkout_failed' ? 'Could not start checkout. Try again.' : `Error: ${r.error}`);
  });
}
```

- [ ] **Step 4: Verify in the browser.** Serve the site statically and open `/pricing`.

Start a static server (any; example): `npx --yes serve site -l 4173` (or `python3 -m http.server 4173 -d site`). Then open `http://localhost:4173/pricing.html` in the browser tool.
- Confirm: the page renders styled (nav-less flow layout is fine), no console errors on load (read_console_messages).
- Confirm the checkout call fires: with no live API it will error — that's expected; assert the error banner appears (which proves the glue + flow wiring works end-to-end to the fetch). To exercise the success path, point `<meta name="slipreel-api-base">` at a locally-booted API (Task 7 documents this) OR trust the `flow.test.js` unit coverage of `startCheckout`.
- Take a screenshot for the record.

(Automated coverage of the logic is in `flow.test.js`; this step verifies the page renders and is wired.)

- [ ] **Step 5: Commit**

```bash
git add site/assets/css/app.css site/pricing.html site/assets/js/page-pricing.js
git commit -m "feat(site): pricing page starts Stripe checkout"
```

---

### Task 4: Success page (checkout → login → app unlock)

`/success` establishes the session from the checkout id and either deep-links the app or routes to the account. Deliverable: the page renders states (working / opened-app + manual fallback / go-to-account / seat-limit / error), verified in the browser.

**Files:**
- Create: `site/success.html`
- Create: `site/cancel.html`
- Create: `site/assets/js/page-success.js`

**Interfaces:** consumes `completeCheckout` (flow.js).

- [ ] **Step 1: Create `site/success.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Slipreel — You're in</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/css/site.css">
<link rel="stylesheet" href="assets/css/app.css">
</head>
<body>
<main class="flow">
  <h1 class="flow__title" id="title">Finishing up…</h1>
  <p class="flow__sub" id="sub">Confirming your purchase.</p>
  <div class="card hidden" id="panel"></div>
  <div class="status hidden" id="status" role="alert"></div>
</main>
<script type="module" src="assets/js/page-success.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create `site/cancel.html`** (checkout cancel_url target)

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Slipreel — Checkout canceled</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/css/site.css">
<link rel="stylesheet" href="assets/css/app.css">
</head>
<body>
<main class="flow">
  <h1 class="flow__title">Checkout canceled</h1>
  <p class="flow__sub">No charge was made.</p>
  <a class="btn btn--primary btn--block" href="pricing.html">Back to pricing</a>
</main>
</body>
</html>
```

- [ ] **Step 3: Create `site/assets/js/page-success.js`**

```js
import { apiBase } from './config.js';
import { createApi } from './api.js';
import { completeCheckout } from './flow.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const sessionId = new URLSearchParams(location.search).get('session_id');

const title = document.getElementById('title');
const sub = document.getElementById('sub');
const panel = document.getElementById('panel');
const statusEl = document.getElementById('status');

function fail(msg) {
  title.textContent = 'Something went wrong';
  sub.textContent = '';
  statusEl.textContent = msg;
  statusEl.className = 'status status--err';
}

async function run() {
  if (!sessionId) return fail('Missing checkout session. Open this page from your receipt link.');
  const r = await completeCheckout(api, sessionId);
  if (r.deeplink) {
    title.textContent = 'Opening Slipreel…';
    sub.textContent = 'Your export is unlocked.';
    panel.className = 'card';
    panel.innerHTML = `<p>If Slipreel didn't open automatically:</p>
      <a class="btn btn--primary btn--block" id="open">Open Slipreel</a>`;
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink; // attempt auto-open
    return;
  }
  if (r.account) {
    title.textContent = "You're all set";
    sub.textContent = `Signed in as ${r.account.email}. Export is unlocked in Slipreel.`;
    panel.className = 'card';
    panel.innerHTML = `<a class="btn btn--primary btn--block" href="account.html">Manage your account</a>`;
    return;
  }
  if (r.seatLimit) {
    title.textContent = 'Device limit reached';
    sub.textContent = 'You already have 2 activated devices. Remove one, then reopen Slipreel.';
    panel.className = 'card';
    panel.innerHTML = `<a class="btn btn--primary btn--block" href="account.html">Manage devices</a>`;
    return;
  }
  fail(r.status === 409 ? 'This link was already used. You may already be signed in.' : 'Could not confirm your purchase. Contact hello@slipreel.app.');
}
run();
```

- [ ] **Step 4: Verify in the browser.** Serve the site (as in Task 3). Open `/success.html?session_id=cs_test`.
- With no live API, expect the error state ("Could not confirm…") — proves the page runs the flow and renders the failure branch. No console errors besides the expected fetch failure.
- Open `/cancel.html` — confirm it renders with a back-to-pricing button.
- Screenshot both. (The deeplink/account/seat branches are unit-covered in `flow.test.js`; to see them live, point the meta tag at a booted API — Task 7.)

- [ ] **Step 5: Commit**

```bash
git add site/success.html site/cancel.html site/assets/js/page-success.js
git commit -m "feat(site): success page logs in and deep-links the app"
```

---

### Task 5: Login page (magic-link request + verify)

`/login` sends a magic link, and — when opened from an emailed `?token=` — verifies it and performs the same app-unlock/account handoff. Deliverable: both modes render + wire correctly, verified in the browser.

**Files:**
- Create: `site/login.html`
- Create: `site/assets/js/page-login.js`

**Interfaces:** consumes `requestMagicLink` + `completeMagicLink` (flow.js).

- [ ] **Step 1: Create `site/login.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Slipreel — Sign in</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/css/site.css">
<link rel="stylesheet" href="assets/css/app.css">
</head>
<body>
<main class="flow">
  <h1 class="flow__title" id="title">Sign in</h1>
  <p class="flow__sub" id="sub">We'll email you a sign-in link.</p>

  <div class="card" id="request">
    <label class="field">
      <span class="field__label">Email</span>
      <input class="input" id="email" type="email" autocomplete="email" placeholder="you@example.com" required>
    </label>
    <button class="btn btn--primary btn--block" id="send">Email me a link</button>
  </div>

  <div class="card hidden" id="panel"></div>
  <div class="status hidden" id="status" role="alert"></div>
</main>
<script type="module" src="assets/js/page-login.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create `site/assets/js/page-login.js`**

```js
import { apiBase } from './config.js';
import { createApi } from './api.js';
import { requestMagicLink, completeMagicLink } from './flow.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const params = new URLSearchParams(location.search);
const token = params.get('token');
const device = params.get('device');
const deviceName = params.get('device_name');
const state = params.get('state');

const title = document.getElementById('title');
const sub = document.getElementById('sub');
const requestCard = document.getElementById('request');
const panel = document.getElementById('panel');
const statusEl = document.getElementById('status');

function show(el, cls, msg) { el.className = cls; el.textContent = msg; }

async function verifyMode() {
  requestCard.className = 'card hidden';
  title.textContent = 'Signing you in…';
  sub.textContent = '';
  const r = await completeMagicLink(api, token);
  if (r.deeplink) {
    title.textContent = 'Opening Slipreel…';
    panel.className = 'card';
    panel.innerHTML = `<p>If Slipreel didn't open automatically:</p>
      <a class="btn btn--primary btn--block" id="open">Open Slipreel</a>`;
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink;
  } else if (r.account) {
    title.textContent = "You're signed in";
    panel.className = 'card';
    panel.innerHTML = `<a class="btn btn--primary btn--block" href="account.html">Go to your account</a>`;
  } else {
    show(statusEl, 'status status--err', 'This link is invalid or already used. Request a new one.');
    requestCard.className = 'card';
    title.textContent = 'Sign in';
  }
}

function requestModeInit() {
  document.getElementById('send').addEventListener('click', async () => {
    const email = /** @type {HTMLInputElement} */ (document.getElementById('email')).value.trim();
    if (!email) return show(statusEl, 'status status--err', 'Enter your email first.');
    statusEl.className = 'status hidden';
    await requestMagicLink(api, { email, device, deviceName, state });
    // Always show the same confirmation (no email-existence leak).
    requestCard.className = 'card hidden';
    title.textContent = 'Check your email';
    sub.textContent = `If ${email} has a Slipreel account, a sign-in link is on its way.`;
  });
}

if (token) verifyMode(); else requestModeInit();
```

- [ ] **Step 3: Verify in the browser.** Serve the site. Open `/login.html`:
- Request mode: type an email, click "Email me a link" → with no live API the request still resolves (fetch fails → `sent:false`), but the UI shows the same neutral "Check your email" confirmation (no leak) — confirm that.
- Verify mode: open `/login.html?token=faketoken` → expect the "invalid or already used" state (live API absent). Confirm the request card reappears.
- No unexpected console errors. Screenshot both modes.

- [ ] **Step 4: Commit**

```bash
git add site/login.html site/assets/js/page-login.js
git commit -m "feat(site): magic-link login and verify handoff"
```

---

### Task 6: Account page (billing portal + devices)

`/account` shows the signed-in user, opens the Stripe billing portal, and lists/deactivates devices. Deliverable: renders the signed-out prompt without a session and the device list + actions with one, verified in the browser.

**Files:**
- Create: `site/account.html`
- Create: `site/assets/js/page-account.js`

**Interfaces:** consumes `createApi` (devices/deleteDevice/portal/logout).

- [ ] **Step 1: Create `site/account.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Slipreel — Account</title>
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/css/site.css">
<link rel="stylesheet" href="assets/css/app.css">
</head>
<body>
<main class="flow">
  <h1 class="flow__title">Your account</h1>
  <p class="flow__sub" id="sub">Loading…</p>

  <div class="card hidden" id="signedout">
    <p>You're not signed in.</p>
    <a class="btn btn--primary btn--block" href="login.html">Sign in</a>
  </div>

  <div class="card hidden" id="billing">
    <label class="field">
      <span class="field__label">Email</span>
      <input class="input" id="email" type="email" autocomplete="email" placeholder="you@example.com">
    </label>
    <button class="btn btn--primary btn--block" id="portal">Manage billing</button>
    <p class="muted">Opens the Stripe customer portal to change plan, update card, or cancel.</p>
  </div>

  <div class="card hidden" id="devices">
    <h2 style="margin:0 0 8px;font-size:1rem;">Devices</h2>
    <div id="deviceList"></div>
  </div>

  <div class="status hidden" id="status" role="alert"></div>
  <p><a class="muted" href="#" id="logout">Sign out</a></p>
</main>
<script type="module" src="assets/js/page-account.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create `site/assets/js/page-account.js`**

```js
import { apiBase } from './config.js';
import { createApi } from './api.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));

const sub = document.getElementById('sub');
const signedout = document.getElementById('signedout');
const billing = document.getElementById('billing');
const devicesCard = document.getElementById('devices');
const deviceList = document.getElementById('deviceList');
const statusEl = document.getElementById('status');

function err(msg) { statusEl.textContent = msg; statusEl.className = 'status status--err'; }

function renderDevices(devices) {
  deviceList.innerHTML = '';
  if (!devices.length) { deviceList.innerHTML = '<p class="muted">No activated devices.</p>'; return; }
  for (const d of devices) {
    const row = document.createElement('div');
    row.className = 'device-row';
    const name = document.createElement('span');
    name.textContent = d.name || 'Unnamed device';
    const btn = document.createElement('button');
    btn.className = 'btn'; btn.textContent = 'Deactivate';
    btn.addEventListener('click', async () => {
      btn.setAttribute('disabled', 'true');
      const r = await api.deleteDevice(d.id);
      if (r.ok) { await load(); } else { err('Could not remove that device.'); btn.removeAttribute('disabled'); }
    });
    row.append(name, btn);
    deviceList.append(row);
  }
}

async function load() {
  const r = await api.devices();
  if (r.status === 401) {
    sub.textContent = '';
    signedout.className = 'card';
    return;
  }
  if (!r.ok) return err('Could not load your account.');
  sub.textContent = 'Manage billing and your devices.';
  billing.className = 'card';
  devicesCard.className = 'card';
  renderDevices(r.data.devices || []);
}

document.getElementById('portal').addEventListener('click', async () => {
  const email = /** @type {HTMLInputElement} */ (document.getElementById('email')).value.trim();
  if (!email) return err('Enter the email you purchased with.');
  const r = await api.portal(email);
  if (r.ok && r.data?.url) { location.href = r.data.url; return; }
  err(r.status === 404 ? 'No billing account for that email.' : 'Could not open billing.');
});

document.getElementById('logout').addEventListener('click', async (e) => {
  e.preventDefault();
  await api.logout();
  location.reload();
});

load();
```

- [ ] **Step 3: Verify in the browser.** Serve the site. Open `/account.html`:
- With no live API, the `devices()` call fails (not a 401) → the "Could not load your account" error shows. To see the signed-out state, you can temporarily point the meta tag at a booted API that returns 401 (no cookie). The device-list rendering + deactivate wiring is exercised against a booted API (Task 7); structurally confirm the three cards and the logout link exist and no console errors on load.
- Screenshot.

- [ ] **Step 4: Commit**

```bash
git add site/account.html site/assets/js/page-account.js
git commit -m "feat(site): account page for billing portal and devices"
```

---

### Task 7: nginx clean URLs, deploy, and local run docs

Serve pretty URLs (`/pricing` → `pricing.html`), ensure the deploy ships the new files, and document the local end-to-end run. Deliverable: an nginx site config with `try_files`, a README/docs note, and a verified local run against a booted API.

**Files:**
- Create: `server/deploy/nginx-site.conf`
- Modify: `server/README.md` (or a `site/README.md`) — local run instructions
- (No change needed to `scripts/deploy-site.sh` — it rsyncs the whole `site/` dir, so new files ship; confirm.)

- [ ] **Step 1: Create `server/deploy/nginx-site.conf`** — the marketing/app static site with clean URLs.

```nginx
# slipreel.app — static marketing site + flow pages (rsync'd to /var/www/slipreel).
# Clean URLs: /pricing -> pricing.html, /login -> login.html, etc.
# TLS via certbot (certbot --nginx -d slipreel.app -d www.slipreel.app).
server {
    listen 80;
    listen [::]:80;
    server_name slipreel.app www.slipreel.app;
    root /var/www/slipreel;
    index index.html;

    # Try the exact path, then <path>.html, then a directory index, else 404.
    location / {
        try_files $uri $uri.html $uri/ =404;
    }

    # Long-cache static assets (fingerprint or bump on deploy as needed).
    location /assets/ {
        try_files $uri =404;
        add_header Cache-Control "public, max-age=3600";
    }
}
```

- [ ] **Step 2: Confirm the deploy ships new files.** `scripts/deploy-site.sh` rsyncs `site/` → the webroot (no `--delete`), so `pricing.html`, `login.html`, `account.html`, `success.html`, `cancel.html`, and `assets/js/*`, `assets/css/app.css` are all included. Read the script to confirm it copies the directory tree (it does). No change required; note it in the report.

- [ ] **Step 3: Add local-run docs.** Append to `server/README.md` a "Local end-to-end (web flow)" section:

````markdown
## Local end-to-end (web flow)

Run the API and the static site together to click through the pages:

1. Boot the API with local-friendly config in `server/.env` (test mode):
   - `CORS_ORIGINS=http://localhost:4173`
   - Stripe test keys + price ids (`npm run stripe:bootstrap`), entitlement keys
     (`npm run gen:entitlement-keys`), and optionally `RESEND_API_KEY`.
   - Then `npm run dev`.
2. Serve the site on the origin you allowed:
   ```bash
   npx --yes serve site -l 4173
   ```
3. Point the pages at the local API by adding to each page's `<head>` for local
   testing (or serve behind the same origin): `<meta name="slipreel-api-base" content="http://localhost:8080">`.
   (In production the pages auto-resolve `https://api.slipreel.app`; the meta tag
   is only for local dev — do not commit it into the pages.)
4. Open `http://localhost:4173/pricing.html`, use Stripe test card `4242 4242 4242 4242`,
   and follow the redirect back to `/success.html`.
````

- [ ] **Step 4: Local verification against a booted API.** With the API booted (CORS allowing your static origin, Stripe test keys set) and the site served:
- Open `/pricing.html`, enter an email, click Yearly → confirm the redirect to Stripe Checkout (`checkout.stripe.com`).
- Complete payment with `4242 4242 4242 4242` → land on `/success.html` → confirm the "You're all set / Manage your account" (web flow) state, and that `/account.html` then lists no devices and can open the portal.
- Read console + network to confirm the `/v1/checkout`, `/v1/auth/session-from-checkout`, and `/v1/devices` calls succeed (200) with the cookie set.
- Screenshot the success + account pages. (If you cannot boot with live Stripe keys in this environment, record that the render + unit coverage stand in, and this live run is the operator's pre-launch check.)

- [ ] **Step 5: Commit**

```bash
git add server/deploy/nginx-site.conf server/README.md
git commit -m "feat(deploy): nginx clean URLs for the site + local run docs"
```

---

## Self-Review

**Spec coverage (Phase 4b — spec §10 pages + §8 handoff):**
- `/pricing` (start checkout, carry device/state) → Task 3. `/success` (session-from-checkout → mint token → `slipreel://` deep link, with account + seat-limit branches) → Task 4. `/login` (magic-link request + verify handoff) → Task 5. `/account` (Stripe portal + device list/deactivate + logout) → Task 6. Clean URLs + deploy + local run → Task 7. The DOM-free logic (`api.js`/`flow.js`/`config.js`) is unit-tested (Tasks 1–2) with `node --test`, matching the repo convention.
- Out of scope (documented): reconciling the `index.html` marketing pricing ($149 lifetime vs $99 one-time) and wiring its CTAs to `/pricing`; server-side `state` validation (Phase 5); the Flutter deep-link handler + export gate (Phase 5/6); a real Resend/DNS setup for live sends.

**Placeholder scan:** No TBD/TODO. The `<meta name="slipreel-api-base">` dev override is documented as dev-only and intentionally not committed into the pages; production auto-resolves the API base. Every page has complete markup + glue.

**Type consistency:** `createApi(...)` method names (`checkout`/`sessionFromCheckout`/`token`/`magicLink`/`magicLinkVerify`/`portal`/`devices`/`deleteDevice`/`logout`) match every `flow.js` call and every page glue call. `flow.js` return shapes (`{redirect}`/`{deeplink}`/`{account}`/`{seatLimit}`/`{error,status}`/`{sent}`) match the branches each page renders. `buildDeeplink` param names (`token`/`refresh_token`/`device_id`/`state`) match the `/v1/token` response fields the API returns. `apiBase(hostname, metaContent)` matches its call sites in every page glue.

**Browser-verification note:** unlike Phases 1–4a (pure vitest), the page tasks (3–6) end with a browser render/interaction check because the deliverable is visual. The risky logic is covered by `node --test` (Tasks 1–2); the page steps verify rendering, wiring, and the absence of console errors. A full live click-through needs a booted API with Stripe test keys (Task 7 / operator pre-launch).

---

## Execution Handoff

Choose how to execute — see the offer in chat. Note: Tasks 1–2 are pure `node --test` logic (well-suited to autonomous subagents); Tasks 3–7 involve browser render verification, which benefits from inline execution (driving the browser to confirm the pages look right and are wired) — I'll recommend a hybrid at handoff.
