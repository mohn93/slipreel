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

function renderDevices(devices) {
  deviceList.innerHTML = '';
  if (!devices.length) { deviceList.innerHTML = '<p class="muted">No activated devices.</p>'; return; }
  for (const d of devices) {
    const row = document.createElement('div');
    row.className = 'device-row';
    const name = document.createElement('span');
    name.textContent = d.name || 'Unnamed device';
    const btn = document.createElement('button');
    btn.className = 'btn'; btn.textContent = 'Deactivate';
    btn.addEventListener('click', async () => {
      btn.setAttribute('disabled', 'true');
      const r = await api.deleteDevice(d.id);
      if (r.ok) { await load(); } else { err('Could not remove that device.'); btn.removeAttribute('disabled'); }
    });
    row.append(name, btn);
    deviceList.append(row);
  }
}

async function load() {
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
  const email = /** @type {HTMLInputElement} */ (document.getElementById('email')).value.trim();
  if (!email) return err('Enter the email you purchased with.');
  const r = await api.portal(email);
  if (r.ok && r.data?.url) { location.href = r.data.url; return; }
  err(r.status === 404 ? 'No billing account for that email.' : 'Could not open billing.');
});

document.getElementById('logout').addEventListener('click', async (e) => {
  e.preventDefault();
  await api.logout();
  location.reload();
});

load();
