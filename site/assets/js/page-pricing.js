import { apiBase } from './config.js';
import { createApi } from './api.js';
import { startCheckout } from './flow.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const params = new URLSearchParams(location.search);
const device = params.get('device');
const state = params.get('state');
const deviceName = params.get('device_name');

const plansEl = document.getElementById('plans');
const statusEl = document.getElementById('status');
const emailEl = /** @type {HTMLInputElement} */ (document.getElementById('email'));
const cta = document.getElementById('continue');

// Yearly is pre-selected in the markup (the anchor / best-value default).
let selected = 'yearly';

function selectPlan(plan) {
  selected = plan;
  for (const b of plansEl.querySelectorAll('.pw__plan')) {
    const on = b.dataset.plan === plan;
    b.classList.toggle('is-selected', on);
    b.setAttribute('aria-checked', on ? 'true' : 'false');
  }
}

for (const b of plansEl.querySelectorAll('.pw__plan')) {
  b.addEventListener('click', () => selectPlan(b.dataset.plan));
}

function showError(msg) {
  statusEl.textContent = msg;
  statusEl.className = 'status status--err';
}

async function go() {
  const email = emailEl.value.trim();
  if (!email) {
    showError('Enter your email to continue.');
    emailEl.focus();
    return;
  }
  statusEl.className = 'status hidden';
  cta.setAttribute('disabled', 'true');
  cta.textContent = 'Starting checkout…';
  const r = await startCheckout(api, { email, plan: selected, device, deviceName, state });
  if (r.redirect) {
    location.href = r.redirect;
    return;
  }
  cta.removeAttribute('disabled');
  cta.textContent = 'Continue to checkout';
  showError(r.error === 'checkout_failed' ? 'Could not start checkout. Try again.' : `Error: ${r.error}`);
}

cta.addEventListener('click', go);
emailEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') go();
});
