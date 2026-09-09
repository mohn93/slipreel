import { itemsFromDocument, formatBytes } from './appcast.js?v=7';
import { eligibleReleases, safeDownloadUrl } from './release-list.js';
const list = document.getElementById('releases');
const status = document.getElementById('download-status');
const ceiling = document.getElementById('ceiling');
let available = [];
const requestedCeiling = new URLSearchParams(location.search).get('until');
if (/^\d{4}-\d{2}-\d{2}$/.test(requestedCeiling || '')) ceiling.value = requestedCeiling;
function render() {
  list.replaceChildren();
  const releases = eligibleReleases(available, ceiling.value);
  for (const release of releases) {
    const item = document.createElement('li');
    const link = document.createElement('a');
    link.href = release.url;
    link.textContent = `Slipreel ${release.version}`;
    item.append(link, ` — ${release.date.slice(0, 10)} · ${formatBytes(release.length) || 'DMG'}`);
    list.append(item);
  }
  status.textContent = releases.length ? `${releases.length} available releases. Dates are release dates in UTC.`
    : 'No available release matches this date. Contact support for help with your eligible version.';
}
ceiling.addEventListener('change', render);
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
    available = results.filter(Boolean);
    render();
  } catch {
    status.textContent = 'Downloads could not be checked. Please reload, or contact support for an eligible version.';
  }
}
load();
