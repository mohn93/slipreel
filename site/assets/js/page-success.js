import { apiBase } from './config.js';
import { createApi } from './api.js?v=7';
import { completeCheckout } from './flow.js?v=7';
import { consumeCredentialParams } from './credential-safety.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const sessionId = consumeCredentialParams(location, history).get('session_id');
let busy = false;

const title = document.getElementById('title');
const sub = document.getElementById('sub');
const panel = document.getElementById('panel');
const statusEl = document.getElementById('status');

function fail(msg) {
  title.textContent = 'Something went wrong';
  sub.textContent = '';
  statusEl.textContent = msg;
  statusEl.className = 'status status--err';
  panel.className = 'card';
  panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Check your account</a><a class="btn btn--block" href="mailto:hello@slipreel.app">Contact support</a>';
}

async function run() {
  if (busy) return;
  if (!sessionId) return fail('No checkout to confirm. Sign in to your account to check your license.');
  busy = true;
  const retry = document.getElementById('retry');
  if (retry) retry.disabled = true;
  const r = await completeCheckout(api, sessionId, { onPending: () => {
    sub.textContent = 'Waiting for payment confirmation. This can take a moment; please keep this page open.';
  } });
  busy = false;
  if (r.pending) {
    title.textContent = 'Payment confirmation is still pending';
    sub.textContent = 'You do not need to purchase again. We will activate your license when payment is confirmed. Check again here, or sign in from Slipreel later.';
    panel.className = 'card';
    panel.innerHTML = '<button class="btn btn--primary btn--block" id="retry">Check payment again</button><a class="btn btn--block" href="account.html">View account</a>';
    document.getElementById('retry').addEventListener('click', run);
    return;
  }
  if (r.status === 401) {
    title.textContent = 'Sign in to confirm your purchase';
    sub.textContent = 'Verify the email you used at checkout. Your purchase will be kept.';
    panel.className = 'card';
    panel.innerHTML = '<a class="btn btn--primary btn--block" id="signin">Email me a sign-in link</a>';
    document.getElementById('signin').href = 'login.html?' + new URLSearchParams({ checkout_session_id: sessionId });
    return;
  }
  if (r.deeplink) {
    title.textContent = 'Opening Slipreel…';
    sub.textContent = 'Slipreel will confirm your license and export access.';
    panel.className = 'card';
    panel.innerHTML = "<p>If Slipreel didn't open automatically:</p>"
      + '<a class="btn btn--primary btn--block" id="open">Open Slipreel</a>';
    document.getElementById('open').setAttribute('href', r.deeplink);
    location.href = r.deeplink; // attempt auto-open
    return;
  }
  if (r.account) {
    title.textContent = "You're all set";
    sub.textContent = `Your purchase is ready for ${r.account.email}. Install Slipreel, then choose Sign in in the app to activate this Mac.`;
    panel.className = 'card';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="guide.html">Install and activate Slipreel</a><a class="btn btn--block" href="account.html">Manage your account</a>';
    return;
  }
  if (r.seatLimit || r.phase === 'activation') {
    title.textContent = r.seatLimit ? 'Device limit reached' : 'Purchase confirmed; activation needs another try';
    sub.textContent = r.seatLimit ? 'You already have 2 activated devices. Remove one, then sign in again from Slipreel.' : 'Return to Slipreel and choose Sign in again. You do not need to purchase again.';
    panel.className = 'card';
    panel.innerHTML = '<a class="btn btn--primary btn--block" href="account.html">Manage devices</a>';
    if (r.errorDeeplink) {
      const back = document.createElement('a');
      back.textContent = 'Return to Slipreel';
      back.className = 'btn btn--block';
      back.href = r.errorDeeplink;
      panel.append(back);
      location.href = r.errorDeeplink;
    }
    return;
  }
  if (r.error === 'payment_failed') return fail('The payment did not succeed. Check your account and payment method before trying a new checkout.');
  if (r.error === 'checkout_expired') return fail('This checkout expired before payment was completed. Check your account before starting a new purchase.');
  if (r.error === 'payment_not_entitled') return fail('This payment does not currently provide an active license. Check your account and billing status, or contact support. Do not purchase again just to retry activation.');
  if (r.status === 403) return fail('This checkout belongs to a different account. Sign out, then sign in with the email used for the purchase.');
  fail('Could not confirm your purchase. Check your account or contact support before purchasing again.');
}
run();
