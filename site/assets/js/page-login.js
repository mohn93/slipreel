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

function show(el, cls, msg) {
  el.className = cls;
  el.textContent = msg;
}

// The sign-in token is single-use. Email providers (Gmail, corporate scanners)
// often PREFETCH links in a headless browser, which would run the verify and
// burn the token before the human clicks. So we do NOT verify on page load --
// we show a button and only verify on a real click, which scanners don't do.
function verifyMode() {
  requestCard.className = 'card hidden';
  title.textContent = 'Complete sign-in';
  sub.textContent = 'Confirm on this device to finish signing in to Slipreel.';
  panel.className = 'card';
  panel.innerHTML = '<button class="btn btn--primary btn--block" id="confirm">Sign in to Slipreel</button>';
  document.getElementById('confirm').addEventListener('click', doVerify);
}

async function doVerify() {
  const btn = document.getElementById('confirm');
  if (btn) {
    btn.setAttribute('disabled', 'true');
    btn.textContent = 'Signing you in…';
  }
  statusEl.className = 'status hidden';
  const r = await completeMagicLink(api, token);
  if (r.deeplink) {
    title.textContent = 'Opening Slipreel…';
    panel.innerHTML = "<p class=\"muted\">If Slipreel didn't open automatically:</p>"
      + '<a class="btn btn--primary btn--block" id="open">Open Slipreel</a>';
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink;
  } else if (r.account) {
    title.textContent = "You're signed in";
    sub.textContent = '';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Go to your account</a>';
  } else {
    // Invalid / expired / already used: fall back to requesting a fresh link.
    panel.className = 'card hidden';
    requestCard.className = 'card';
    title.textContent = 'Sign in';
    sub.textContent = "That link didn't work — it may have expired or already been used. Get a new one:";
    show(statusEl, 'status status--err', 'This link is invalid or already used. Request a new one.');
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

// Always wire the request button (used both as the entry point and as the
// fallback after a failed verify), then verify only if a token is present.
requestModeInit();
if (token) verifyMode();
