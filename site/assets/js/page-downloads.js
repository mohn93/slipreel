import { createApi } from './api.js?v=7';
import { apiBase } from './config.js';
import { downloadAccess } from './download-access.js?v=1';
import { itemsFromDocument, formatBytes } from './appcast.js?v=7';
import { eligibleReleases, safeDownloadUrl } from './release-list.js';
const list = document.getElementById('releases');
const status = document.getElementById('download-status');
const api = createApi(apiBase(location.hostname), (url, options) => fetch(url, { ...options, cache: 'no-store' }));
const licenseHeading = document.getElementById('license-heading');
const licenseDetail = document.getElementById('license-detail');
const licenseAction = document.getElementById('license-action');
const licenseRetry = document.getElementById('license-retry');
let available = [];
let feedState = 'loading';
let access = { mode: 'loading', ceiling: '' };
let licenseRequest;
function renderLicense() {
  const copy = {
    visitor: ['Already purchased Slipreel?', 'Sign in and we’ll find the newest version covered by your license.', 'Sign in to find your version', 'login.html'],
    free: ['Try Slipreel for Mac', 'Your account has no active paid license. Download the latest version to try Slipreel.', 'View your account', 'account.html'],
    subscription: ['Your subscription covers the latest release', access.grace ? 'Your payment needs attention. Your downloads remain covered during the grace period.' : 'All available releases are included. The latest version is recommended below.', 'Manage subscription', 'account.html'],
    onetime: ['Your one-time license', `Updates included through ${access.ceiling ? new Intl.DateTimeFormat('en', { dateStyle: 'long', timeZone: 'UTC' }).format(new Date(access.ceiling + 'T00:00:00Z')) : ''}. We’ve selected the releases covered by your purchase.`, 'Manage license', 'account.html'],
    error: ['We couldn’t check your license', 'Try again to find a version covered by your purchase. Your account and purchases haven’t changed.', '', 'account.html'],
    loading: ['Finding the right version for you…', 'Checking your account for a Slipreel license.', '', 'account.html'],
  }[access.mode];
  licenseHeading.textContent = copy[0]; licenseDetail.textContent = copy[1];
  licenseAction.hidden = !copy[2]; licenseAction.textContent = copy[2]; licenseAction.href = copy[3];
  licenseRetry.hidden = access.mode !== 'error';
  document.getElementById('releases-heading').textContent = access.mode === 'onetime' ? 'Your covered releases' : 'Release history';
}
async function checkLicense() {
  if (licenseRequest) return licenseRequest;
  licenseRequest = (async () => {
    access = { mode: 'loading', ceiling: '' }; renderLicense(); list.replaceChildren();
    status.textContent = 'Checking your license…';
    access = downloadAccess(await api.entitlement());
    renderLicense(); render();
  })();
  try { await licenseRequest; } finally { licenseRequest = null; }
}
function render() {
  list.replaceChildren();
  if (['loading', 'error'].includes(access.mode)) { status.textContent = access.mode === 'error' ? 'Downloads will appear after your license is checked.' : 'Checking your license…'; return; }
  if (feedState !== 'ready') { status.textContent = feedState === 'error' ? 'Downloads could not be checked. Please reload, or contact support for your version.' : 'Checking available releases…'; return; }
  const releases = eligibleReleases(available, access.ceiling);
  const dateFormat = new Intl.DateTimeFormat('en', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
  for (const [index, release] of releases.entries()) {
    const item = document.createElement('li');
    item.className = 'release-row';
    const title = document.createElement('div');
    title.className = 'release-title';
    title.textContent = `Slipreel ${release.version}`;
    if (index === 0) {
      const badge = document.createElement('span');
      badge.className = 'release-badge';
      badge.textContent = ['onetime', 'subscription'].includes(access.mode) ? 'Recommended' : 'Latest';
      title.append(badge);
    }
    const date = document.createElement('time');
    date.className = 'release-date';
    date.dateTime = release.date.slice(0, 10);
    date.textContent = dateFormat.format(new Date(release.date));
    const size = document.createElement('span');
    size.className = 'release-size';
    size.textContent = formatBytes(release.length) || 'DMG';
    const link = document.createElement('a');
    link.className = 'release-download';
    link.href = release.url;
    link.textContent = 'Download';
    link.setAttribute('aria-label', `Download Slipreel ${release.version}, ${size.textContent}`);
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox', '0 0 24 24');
    icon.setAttribute('width', '16');
    icon.setAttribute('height', '16');
    icon.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M12 3v12m-4-4 4 4 4-4M5 16v4h14v-4');
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '1.6');
    path.setAttribute('stroke-linecap', 'round');
    path.setAttribute('stroke-linejoin', 'round');
    icon.append(path);
    link.append(icon);
    item.append(title, date, size, link);
    list.append(item);
  }
  status.textContent = releases.length ? `${releases.length} available releases. Dates are release dates in UTC.`
    : 'No available release is covered by your license. Contact support for help finding your version.';
}
licenseRetry.addEventListener('click', checkLicense);
window.addEventListener('focus', checkLicense);
async function load() {
  try {
    const response = await fetch('/appcast.xml', { cache: 'no-cache' });
    if (!response.ok) throw new Error('feed unavailable');
    const doc = new DOMParser().parseFromString(await response.text(), 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) throw new Error('invalid feed');
    const items = itemsFromDocument(doc).filter((item) => safeDownloadUrl(item.url) && item.date);
    // Verify availability; an old appcast entry alone is not a working archive.
    const results = await Promise.all(items.map(async (item) => {
      try {
        const check = await fetch(item.url, { method: 'HEAD', signal: AbortSignal.timeout(10000) });
        return check.ok ? item : null;
      } catch { return null; }
    }));
    available = eligibleReleases(results.filter(Boolean), '');
    feedState = 'ready';
    render();
  } catch {
    feedState = 'error';
    render();
  }
}
checkLicense();
load();
