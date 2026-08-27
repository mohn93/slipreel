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
