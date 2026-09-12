import { apiBase } from './config.js';
import { createApi } from './api.js?v=7';

const meta = document.querySelector('meta[name="slipreel-api-base"]');
const api = createApi(apiBase(location.hostname, meta ? meta.content : null));

const sub = document.getElementById('sub');
const signedout = document.getElementById('signedout');
const planCard = document.getElementById('plan');
const planDot = document.getElementById('planDot');
const planName = document.getElementById('planName');
const planDetail = document.getElementById('planDetail');
const upgrade = document.getElementById('upgrade');
const billing = document.getElementById('billing');
const downloadCard = document.getElementById('download');
const devicesCard = document.getElementById('devices');
const deviceList = document.getElementById('deviceList');
const statusEl = document.getElementById('status');

function err(msg) { statusEl.textContent = msg; statusEl.className = 'status status--err'; }

function formatDate(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  return isNaN(d) ? null : d.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
}

// Map an effective entitlement ({ plan, status, updatesUntil }) to the
// coloured dot, headline, and detail line shown at the top of the account.
function renderPlan(e) {
  let dot = 'plan-dot plan-dot--off';
  let name = 'No active license';
  let detail = 'Records and edits are free. A license unlocks unlimited exports.';
  let showUpgrade = true;

  if (e && e.plan === 'subscription') {
    showUpgrade = false;
    if (e.status === 'grace') {
      dot = 'plan-dot plan-dot--warn';
      name = 'Pro — Monthly';
      detail = 'Payment issue — update your card to keep exporting.';
    } else {
      dot = 'plan-dot plan-dot--ok';
      name = 'Pro — Monthly';
      detail = 'Active. Unlimited exports on your devices.';
    }
  } else if (e && e.plan === 'onetime') {
    showUpgrade = false;
    dot = 'plan-dot plan-dot--ok';
    name = 'One-time license';
    const until = formatDate(e.updatesUntil);
    const expired = e.updatesUntil && Date.parse(e.updatesUntil) < Date.now();
    detail = until ? `Your license includes releases through ${until} (UTC). ${expired ? 'Keep using an eligible version or renew for newer releases.' : 'Unlimited exports on eligible versions.'}` : 'Active. Unlimited exports.';
    showUpgrade = !!expired;
    upgrade.textContent = expired ? 'Renew for another year of updates' : 'Upgrade for unlimited exports';
    upgrade.href = 'pricing.html?plan=onetime';
    document.getElementById('eligible-download').href = 'downloads.html';
  }

  planDot.className = dot;
  planName.textContent = name;
  planDetail.textContent = detail;
  upgrade.className = showUpgrade ? 'btn btn--primary btn--block' : 'btn btn--primary btn--block hidden';
  planCard.className = 'card';
}

function relativeTime(iso) {
  if (!iso) return null;
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return 'just now';
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min${m === 1 ? '' : 's'} ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} hour${h === 1 ? '' : 's'} ago`;
  const d = Math.round(h / 24);
  if (d < 30) return `${d} day${d === 1 ? '' : 's'} ago`;
  return new Date(iso).toLocaleDateString();
}

function renderDevices(devices) {
  deviceList.innerHTML = '';
  if (!devices.length) { deviceList.innerHTML = '<p class="muted">No activated devices.</p>'; return; }
  for (const d of devices) {
    const row = document.createElement('div');
    row.className = 'device-row';

    const info = document.createElement('div');
    info.className = 'device-info';
    const name = document.createElement('span');
    name.className = 'device-name';
    name.textContent = d.name || 'Unnamed device';
    const sub = document.createElement('span');
    sub.className = 'device-sub';
    const bits = [];
    if (d.location) bits.push(d.location);
    const last = relativeTime(d.last_seen_at);
    bits.push(last ? `Last active ${last}` : `Added ${new Date(d.created_at).toLocaleDateString()}`);
    sub.textContent = bits.join(' · ');
    info.append(name, sub);

    const btn = document.createElement('button');
    btn.className = 'btn'; btn.textContent = 'Deactivate';
    btn.addEventListener('click', async () => {
      btn.setAttribute('disabled', 'true');
      const r = await api.deleteDevice(d.id);
      if (r.ok) { await load(); } else { err('Could not remove that device.'); btn.removeAttribute('disabled'); }
    });

    row.append(info, btn);
    deviceList.append(row);
  }
}

async function load() {
  statusEl.className = 'status hidden';
  const [devicesRes, entRes] = await Promise.all([api.devices(), api.entitlement()]);
  if (devicesRes.status === 401) {
    sub.textContent = '';
    signedout.className = 'card';
    planCard.className = 'card hidden';
    billing.className = 'card hidden';
    downloadCard.className = 'card hidden';
    devicesCard.className = 'card hidden';
    return;
  }
  if (!devicesRes.ok) return err('Could not load your account.');
  sub.textContent = 'Your plan, billing, and devices.';
  signedout.className = 'card hidden';
  if (!entRes.ok) return err('Could not load your license. Reload to try again.');
  renderPlan(entRes.data);
  const portalButton = document.getElementById('portal');
  portalButton.dataset.provider = entRes.data.billingProvider || 'stripe';
  portalButton.textContent = entRes.data.billingProvider === 'apple' ? 'Manage Apple subscription' : 'Manage billing';
  billing.className = 'card';
  downloadCard.className = 'card';
  devicesCard.className = 'card';
  renderDevices(devicesRes.data.devices || []);
}

document.getElementById('portal').addEventListener('click', async () => {
  statusEl.className = 'status hidden';
  const btn = document.getElementById('portal');
  btn.setAttribute('disabled', 'true');
  if (btn.dataset.provider === 'apple') { location.href = 'https://apps.apple.com/account/subscriptions'; return; }
  const r = await api.portal();
  if (r.ok && r.data?.url) { location.href = r.data.url; return; }
  btn.removeAttribute('disabled');
  err(r.status === 404 ? 'No billing found for your account yet.' : 'Could not open billing.');
});

document.getElementById('logout').addEventListener('click', async (e) => {
  e.preventDefault();
  await api.logout();
  location.reload();
});

load();
