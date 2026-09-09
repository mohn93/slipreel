import { apiBase } from './config.js';
import { createApi } from './api.js?v=7';
import { startCheckout, requestMagicLink } from './flow.js?v=7';
import { checkoutPlan } from './pricing-plan.js';
import { consumeCredentialParams } from './credential-safety.js';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));
const params = consumeCredentialParams(location, history);
let device = params.get('device');
let state = params.get('state');
let deviceName = params.get('device_name');
const flow = params.get('flow');
const plansEl = document.getElementById('plans');
const statusEl = document.getElementById('status');
const emailEl = document.getElementById('email');
const cta = document.getElementById('continue');
const form = document.getElementById('purchase');
let selected = checkoutPlan(params);
let busy = false;
let signedIn = false;
let contextReady = !flow;

function selectPlan(plan, focus = false) {
  selected = plan;
  for (const b of plansEl.querySelectorAll('.pw__plan')) {
    const on = b.dataset.plan === plan;
    b.classList.toggle('is-selected', on);
    b.setAttribute('aria-checked', String(on));
    b.tabIndex = on ? 0 : -1;
    if (on && focus) b.focus();
  }
}
selectPlan(selected);
const buttons = [...plansEl.querySelectorAll('.pw__plan')];
for (const [index, b] of buttons.entries()) {
  b.addEventListener('click', () => selectPlan(b.dataset.plan));
  b.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1
      : (index + (['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 1) + buttons.length) % buttons.length;
    selectPlan(buttons[next].dataset.plan, true);
  });
}
function showError(message) {
  statusEl.textContent = message;
  statusEl.className = 'status status--err';
}
async function init() {
  cta.disabled = true;
  const session = await api.entitlement();
  signedIn = session.ok;
  if (signedIn && flow) {
    const context = await api.checkoutContext(flow);
    if (!context.ok) {
      showError('This checkout link has expired. Start checkout again from Slipreel to activate this Mac.');
      return;
    }
    ({ device, state, device_name: deviceName } = context.data);
    selectPlan(context.data.plan);
    contextReady = true;
  }
  if (flow && !signedIn) {
    plansEl.classList.add('hidden');
    statusEl.textContent = 'Verify your email to restore your canceled checkout. You can change the plan before paying.';
    statusEl.className = 'status';
  }
  emailEl.closest('label').classList.toggle('hidden', signedIn);
  emailEl.required = !signedIn;
  cta.textContent = signedIn ? 'Continue to secure checkout' : 'Email me a checkout link';
  cta.disabled = false;
}
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (busy || cta.disabled) return;
  busy = true;
  cta.disabled = true;
  statusEl.className = 'status hidden';
  if (signedIn && contextReady) {
    cta.textContent = 'Starting checkout…';
    const result = await startCheckout(api, { plan: selected, device, deviceName, state });
    if (result.redirect) { location.href = result.redirect; return; }
    if (result.status === 401) {
      signedIn = false;
      emailEl.closest('label').classList.remove('hidden');
      emailEl.required = true;
      showError('Your session expired. Verify your email to continue.');
    } else showError('Could not start checkout. Please try again.');
  } else {
    cta.textContent = 'Sending link…';
    const result = await requestMagicLink(api, {
      email: emailEl.value.trim(), device, deviceName, state,
      checkoutPlan: flow ? undefined : selected, checkoutFlow: flow,
    });
    if (result.sent) {
      statusEl.textContent = 'Check your email. Open the link to verify your address and continue to checkout. Your plan and Mac activation details will be kept.';
      statusEl.className = 'status';
    } else showError('Could not send your link. Please try again.');
  }
  busy = false;
  cta.disabled = false;
  cta.textContent = signedIn ? 'Continue to secure checkout' : 'Email me a checkout link';
});
init();
