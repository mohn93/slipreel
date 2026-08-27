// Resolve the API base URL. Pure (no DOM) so it is unit-testable under node:test.
// Production: the api. subdomain. Dev: an explicit <meta> override, else host:8080.
export function apiBase(hostname, metaContent) {
  if (hostname === 'slipreel.app' || hostname === 'www.slipreel.app') {
    return 'https://api.slipreel.app';
  }
  if (metaContent) return metaContent;
  return `http://${hostname}:8080`;
}
