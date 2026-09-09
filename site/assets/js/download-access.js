// Use the effective, session-scoped license. URL dates are never account data.
export function downloadAccess(result) {
  if (result.status === 401) return { mode: 'visitor', ceiling: '' };
  if (!result.ok || !result.data) return { mode: 'error', ceiling: '' };
  const e = result.data;
  if (e.plan === 'onetime' && e.status === 'active' && e.export === true) {
    const date = e.updatesUntil;
    if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(date) || !Number.isFinite(Date.parse(date))) return { mode: 'error', ceiling: '' };
    return { mode: 'onetime', ceiling: new Date(date).toISOString().slice(0, 10) };
  }
  if (e.plan === 'subscription' && ['active', 'grace'].includes(e.status) && e.export === true) return { mode: 'subscription', ceiling: '', grace: e.status === 'grace' };
  if (e.plan === 'free' && e.export === false) return { mode: 'free', ceiling: '' };
  return { mode: 'error', ceiling: '' };
}
