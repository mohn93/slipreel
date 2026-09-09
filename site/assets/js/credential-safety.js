// Never persist authentication material in browser history or analytics.
const sensitive = /^(token|session_id|checkout_session_id|refresh|refresh_token|device|device_id|device_name|state|flow)$/i;
export function redactUrl(value) {
  if (typeof value !== 'string') return value;
  if (/^slipreel:/i.test(value)) return '[app callback]';
  try {
    const url = new URL(value, 'https://slipreel.app');
    for (const key of [...url.searchParams.keys()]) if (sensitive.test(key)) url.searchParams.delete(key);
    url.hash = '';
    return url.toString();
  } catch { return '[invalid URL]'; }
}
export function scrubEvent(event) {
  if (!event) return event;
  function scrub(value, key = '') {
    if (sensitive.test(key)) return '[redacted]';
    if (typeof value === 'string' && (/url|href|referrer/i.test(key) || /^slipreel:/i.test(value))) return redactUrl(value);
    if (Array.isArray(value)) return value.map((item) => scrub(item));
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, scrub(v, k)]));
    return value;
  }
  return scrub(event);
}
export function consumeCredentialParams(location, history) {
  const params = new URLSearchParams(location.search);
  const clean = new URLSearchParams(params);
  for (const key of [...clean.keys()]) if (sensitive.test(key)) clean.delete(key);
  history.replaceState(null, '', location.pathname + (clean.size ? '?' + clean : ''));
  return params;
}
