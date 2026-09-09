// Public installers before 1.0.13 were withdrawn. Do not revive cached feed entries.
export const MIN_SUPPORTED_BUILD = 1000013;
export function supportedRelease(item) {
  const build = Number(item?.build);
  return Number.isInteger(build) && build >= MIN_SUPPORTED_BUILD;
}
export function safeDownloadUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname === 'slipreel.app' && !url.port
      && !url.username && !url.password && url.pathname.startsWith('/download/') && url.pathname.endsWith('.dmg');
  } catch { return false; }
}
export function eligibleReleases(items, ceiling) {
  return items.filter((item) => supportedRelease(item) && item.date && (!ceiling || item.date.slice(0, 10) <= ceiling))
    .sort((a, b) => Number(b.build) - Number(a.build));
}
