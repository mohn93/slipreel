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
    panel.innerHTML = "<p>If Slipreel didn't open automatically:</p>"
      + '<a class="btn btn--primary btn--block" id="open">Open Slipreel</a>';
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink; // attempt auto-open
    return;
  }
  if (r.account) {
    title.textContent = "You're all set";
    sub.textContent = `Signed in as ${r.account.email}. Export is unlocked in Slipreel.`;
    panel.className = 'card';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Manage your account</a>';
    return;
  }
  if (r.seatLimit) {
    title.textContent = 'Device limit reached';
    sub.textContent = 'You already have 2 activated devices. Remove one, then reopen Slipreel.';
    panel.className = 'card';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Manage devices</a>';
    return;
  }
  fail(r.status === 409
    ? 'This link was already used. You may already be signed in.'
    : 'Could not confirm your purchase. Contact hello@slipreel.app.');
}
run();
