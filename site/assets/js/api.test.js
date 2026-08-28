import test from 'node:test';
import assert from 'node:assert/strict';
import { createApi } from './api.js';

function fakeFetch(record, response = { ok: true, status: 200, body: { url: 'u' } }) {
  return async (url, init) => {
    record.url = url; record.init = init;
    return {
      ok: response.ok, status: response.status,
      json: async () => response.body,
    };
  };
}

test('checkout POSTs JSON with credentials', async () => {
  const rec = {};
  const api = createApi('https://api.slipreel.app', fakeFetch(rec));
  const r = await api.checkout({ email: 'a@b.com', plan: 'yearly' });
  assert.equal(rec.url, 'https://api.slipreel.app/v1/checkout');
  assert.equal(rec.init.method, 'POST');
  assert.equal(rec.init.credentials, 'include');
  assert.equal(rec.init.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(rec.init.body), { email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { ok: true, status: 200, data: { url: 'u' } });
});

test('sessionFromCheckout wraps the id', async () => {
  const rec = {};
  const api = createApi('https://x', fakeFetch(rec, { ok: true, status: 200, body: { user: {} } }));
  await api.sessionFromCheckout('cs_1');
  assert.equal(rec.url, 'https://x/v1/auth/session-from-checkout');
  assert.deepEqual(JSON.parse(rec.init.body), { checkout_session_id: 'cs_1' });
});

test('devices is a credentialed GET with no body', async () => {
  const rec = {};
  const api = createApi('https://x', fakeFetch(rec, { ok: true, status: 200, body: { devices: [] } }));
  await api.devices();
  assert.equal(rec.url, 'https://x/v1/devices');
  assert.equal(rec.init.method, 'GET');
  assert.equal(rec.init.credentials, 'include');
  assert.equal(rec.init.body, undefined);
});

test('deleteDevice encodes the id in the path', async () => {
  const rec = {};
  const api = createApi('https://x', fakeFetch(rec, { ok: true, status: 200, body: { ok: true } }));
  await api.deleteDevice('dev_a b');
  assert.equal(rec.url, 'https://x/v1/devices/dev_a%20b');
  assert.equal(rec.init.method, 'DELETE');
});

test('non-2xx and non-JSON bodies surface as {ok:false} with null data', async () => {
  const api = createApi('https://x', async () => ({
    ok: false, status: 409, json: async () => { throw new Error('no json'); },
  }));
  const r = await api.token({ fingerprint: 'fp' });
  assert.equal(r.ok, false); assert.equal(r.status, 409); assert.equal(r.data, null);
});

test('a network error (fetch throws) surfaces as {ok:false, status:0} not a rejection', async () => {
  const api = createApi('https://x', async () => { throw new TypeError('Failed to fetch'); });
  const r = await api.checkout({ email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { ok: false, status: 0, data: null });
});
