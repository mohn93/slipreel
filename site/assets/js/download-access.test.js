import { test } from 'node:test';
import assert from 'node:assert/strict';
import { downloadAccess } from './download-access.js';
import { eligibleReleases } from './release-list.js';
const response = data => ({ ok: true, status: 200, data });
test('one-time account date selects covered releases, including the final UTC day', () => {
  const access = downloadAccess(response({ plan: 'onetime', status: 'active', export: true, updatesUntil: '2026-08-31T23:59:59.000Z' }));
  assert.deepEqual(access, { mode: 'onetime', ceiling: '2026-08-31' });
  assert.deepEqual(eligibleReleases([{ build: 2, date: '2026-09-01T00:00:00Z' }, { build: 1, date: '2026-08-31T23:00:00Z' }], access.ceiling).map(r => r.build), [1]);
});
test('active and grace subscriptions include current releases', () => {
  for (const status of ['active', 'grace']) assert.deepEqual(downloadAccess(response({ plan: 'subscription', status, export: true })), { mode: 'subscription', ceiling: '', grace: status === 'grace' });
});
test('signed-out visitors and free accounts are distinct', () => {
  assert.equal(downloadAccess({ ok: false, status: 401 }).mode, 'visitor');
  assert.equal(downloadAccess(response({ plan: 'free', export: false })).mode, 'free');
});
test('failed or incomplete license checks cannot recommend an uncovered release', () => {
  for (const result of [{ ok: false, status: 503 }, { ok: false, status: 0 }, response(null), response({ plan: 'onetime', status: 'active', export: true, updatesUntil: null }), response({ plan: 'onetime', status: 'active', export: true, updatesUntil: 'invalid' }), response({ plan: 'subscription', status: 'canceled', export: true })]) assert.equal(downloadAccess(result).mode, 'error');
});
