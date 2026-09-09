import { apiBase } from './config.js';
import { createApi } from './api.js?v=7';
import { requestMagicLink, completeMagicLink, startCheckout } from './flow.js?v=7';
import { consumeCredentialParams } from './credential-safety.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const params = consumeCredentialParams(location, history);
const token = params.get('token');
const device = params.get('device');
const deviceName = params.get('device_name');
const state = params.get('state');
const checkoutSessionId = params.get('checkout_session_id');
let busy = false;

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
  if (busy) return;
  busy = true;
  const btn = document.getElementById('confirm');
  if (btn) {
    btn.setAttribute('disabled', 'true');
    btn.textContent = 'Signing you in…';
  }
  statusEl.className = 'status hidden';
  const r = await completeMagicLink(api, token);
  if (r.redirect) { location.href = r.redirect; return; }
  if (r.checkoutSessionId) { location.href = 'success.html?' + new URLSearchParams({ session_id: r.checkoutSessionId }); return; }
  if (r.phase === 'checkout') {
    title.textContent = 'Signed in; checkout needs another try';
    sub.textContent = 'Your email is verified. Your plan and Mac activation details are kept on this page.';
    panel.innerHTML = '<button class="btn btn--primary btn--block" id="retry-checkout">Try checkout again</button>';
    const retry = document.getElementById('retry-checkout');
    retry.addEventListener('click', async () => {
      retry.disabled = true;
      const result = await startCheckout(api, r.checkoutContext);
      if (result.redirect) { location.href = result.redirect; return; }
      retry.disabled = false;
      show(statusEl, 'status status--err', 'Checkout is unavailable. Please try again shortly.');
    });
    return;
  }
  if (r.deeplink) {
    title.textContent = 'Signed in — opening Slipreel…';
    sub.textContent = 'Slipreel will show your license status and whether exports are unlocked.';
    panel.innerHTML = "<p class=\"muted\">If Slipreel didn't open automatically:</p>"
      + '<a class="btn btn--primary btn--block" id="open">Open Slipreel</a>';
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink;
  } else if (r.seatLimit || r.phase === 'activation') {
    title.textContent = r.seatLimit ? 'Device limit reached' : 'Could not activate this Mac';
    sub.textContent = r.seatLimit
      ? 'You are signed in, but your account has reached its device limit. Remove a device, then start sign-in again from Slipreel.'
      : 'You are signed in to the website, but activation could not finish. Return to Slipreel and try signing in again.';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Manage account and devices</a>';
    if (r.errorDeeplink) {
      const back = document.createElement('a');
      back.className = 'btn btn--block';
      back.textContent = 'Return to Slipreel';
      back.href = r.errorDeeplink;
      panel.append(back);
      location.href = r.errorDeeplink;
    }
  } else if (r.account) {
    title.textContent = "You're signed in";
    sub.textContent = '';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Go to your account</a>';
  } else {
    busy = false;
    // Invalid / expired / already used: fall back to requesting a fresh link.
    panel.className = 'card hidden';
    requestCard.className = 'card';
    title.textContent = 'Sign in';
    sub.textContent = "That link didn't work — it may have expired or already been used. Get a new one:";
    show(statusEl, 'status status--err', 'This link is invalid or already used. Request a new one.');
  }
}

function requestModeInit() {
  requestCard.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy) return;
    busy = true;
    const button = document.getElementById('send');
    button.disabled = true;
    const email = document.getElementById('email').value.trim();
    statusEl.className = 'status hidden';
    const result = await requestMagicLink(api, { email, device, deviceName, state, checkoutSessionId });
    busy = false;
    button.disabled = false;
    if (!result.sent) return show(statusEl, 'status status--err', 'Could not request a sign-in link. Check your connection and try again.');
    requestCard.className = 'card hidden';
    title.textContent = 'Check your email';
    sub.textContent = `A sign-in link is on its way to ${email}. Open it to continue.`;
  });
}

// Always wire the request button (used both as the entry point and as the
// fallback after a failed verify), then verify only if a token is present.
requestModeInit();
if (token) verifyMode();
