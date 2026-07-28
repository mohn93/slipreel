import { itemsFromDocument, pickLatestItem, formatBytes } from './appcast.js';

document.documentElement.classList.add('js');

// The download button ships with a working href in the HTML. This only ever
// upgrades it to the newest release; a failure leaves the fallback in place.
async function hydrateDownload() {
  // Task 3 put a download button in BOTH the nav and the hero, so every
  // match must be upgraded — hydrating only the first would leave the
  // hero's primary CTA pinned to the hardcoded fallback.
  const links = [...document.querySelectorAll('[data-download-link]')];
  const badge = document.querySelector('[data-version-badge]');
  if (!links.length) return;
  try {
    const res = await fetch('/appcast.xml', { cache: 'no-cache' });
    if (!res.ok) return;
    const doc = new DOMParser().parseFromString(await res.text(), 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) return;
    const latest = pickLatestItem(itemsFromDocument(doc));
    if (!latest) return;
    links.forEach((link) => { link.href = latest.url; });
    if (badge) {
      const size = formatBytes(latest.length);
      badge.textContent = ['Free download', latest.version && `v${latest.version}`, size]
        .filter(Boolean)
        .join(' · ');
    }
  } catch {
    /* keep the hardcoded fallback */
  }
}

hydrateDownload();
