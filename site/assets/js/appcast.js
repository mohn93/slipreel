// Pure helpers for reading the Sparkle appcast that also drives in-app updates.
// Keeping these free of DOM construction makes them unit-testable under Node.

export function formatBytes(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n <= 0) return null;
  return `${Math.round(n / 1e6)} MB`;
}

export function pickLatestItem(items) {
  const usable = (items || []).filter(
    (i) => i && i.url && Number.isFinite(Number(i.build)) && i.build !== null,
  );
  if (usable.length === 0) return null;
  return usable.reduce((a, b) => (Number(b.build) > Number(a.build) ? b : a));
}

export function itemsFromDocument(doc) {
  const text = (el) => (el && el.textContent ? String(el.textContent).trim() : null);
  return Array.from(doc.getElementsByTagName('item')).map((item) => {
    const enc = item.getElementsByTagName('enclosure')[0];
    return {
      url: enc ? enc.getAttribute('url') : null,
      length: enc ? enc.getAttribute('length') : null,
      version: text(item.getElementsByTagName('sparkle:shortVersionString')[0]),
      build: text(item.getElementsByTagName('sparkle:version')[0]),
    };
  });
}
