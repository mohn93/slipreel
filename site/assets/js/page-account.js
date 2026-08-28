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
  const r = await api.devices();
  if (r.status === 401) {
    sub.textContent = '';
    signedout.className = 'card';
    billing.className = 'card hidden';
    devicesCard.className = 'card hidden';
    return;
  }
  if (!r.ok) return err('Could not load your account.');
  sub.textContent = 'Manage billing and your devices.';
  signedout.className = 'card hidden';
  billing.className = 'card';
  devicesCard.className = 'card';
  renderDevices(r.data.devices || []);
}

document.getElementById('portal').addEventListener('click', async () => {
  statusEl.className = 'status hidden';
  const btn = document.getElementById('portal');
  btn.setAttribute('disabled', 'true');
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
