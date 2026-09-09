import { itemsFromDocument, formatBytes } from './appcast.js?v=7';
import { eligibleReleases, safeDownloadUrl } from './release-list.js';
const list = document.getElementById('releases');
const status = document.getElementById('download-status');
const ceiling = document.getElementById('ceiling');
const clearCeiling = document.getElementById('clear-ceiling');
let available = [];
const requestedCeiling = new URLSearchParams(location.search).get('until');
if (/^\d{4}-\d{2}-\d{2}$/.test(requestedCeiling || '')) ceiling.value = requestedCeiling;
function render() {
  list.replaceChildren();
  const releases = eligibleReleases(available, ceiling.value);
  if (clearCeiling) clearCeiling.hidden = !ceiling.value;
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
      badge.textContent = release.version === available[0]?.version ? 'Latest' : 'Latest covered';
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
    : 'No available release matches this date. Contact support for help with your eligible version.';
}
ceiling.addEventListener('change', render);
clearCeiling?.addEventListener('click', () => { ceiling.value = ''; render(); ceiling.focus(); });
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
    render();
  } catch {
    status.textContent = 'Downloads could not be checked. Please reload, or contact support for an eligible version.';
  }
}
load();
