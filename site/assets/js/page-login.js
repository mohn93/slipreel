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
    panel.innerHTML = "<p>If Slipreel didn't open automatically:</p>"
      + '<a class="btn btn--primary btn--block" id="open">Open Slipreel</a>';
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink;
  } else if (r.account) {
    title.textContent = "You're signed in";
    panel.className = 'card';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Go to your account</a>';
  } else {
    show(statusEl, 'status status--err', 'This link is invalid or already used. Request a new one.');
    requestCard.className = 'card';
    title.textContent = 'Sign in';
    sub.textContent = "We'll email you a sign-in link.";
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
