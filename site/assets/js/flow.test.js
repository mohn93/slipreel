import test from 'node:test';
import assert from 'node:assert/strict';
import { buildDeeplink, startCheckout, completeCheckout, completeMagicLink, requestMagicLink } from './flow.js';

const okToken = { ok: true, status: 200, data: { token: 'jwt', refresh_token: 'rt', device_id: 'dev_1' } };

function apiStub(overrides = {}) {
  return {
    checkout: async () => ({ ok: true, status: 200, data: { url: 'https://checkout.stripe/x' } }),
    sessionFromCheckout: async () => ({ ok: true, status: 200, data: { user: { id: 'user_1', email: 'u@e.com' }, device: null, device_name: null, state: null } }),
    token: async () => okToken,
    magicLinkVerify: async () => ({ ok: true, status: 200, data: { user: { id: 'user_1', email: 'u@e.com' }, device: null, device_name: null, state: null } }),
    magicLink: async () => ({ ok: true, status: 200, data: { sent: true } }),
    ...overrides,
  };
}

test('buildDeeplink includes only present params', () => {
  assert.equal(buildDeeplink({ token: 'jwt' }), 'slipreel://auth?token=jwt');
  assert.equal(
    buildDeeplink({ token: 'j', refresh_token: 'r', device_id: 'd', state: 'n' }),
    'slipreel://auth?token=j&refresh=r&device_id=d&state=n',
  );
});

test('startCheckout returns the redirect url', async () => {
  const r = await startCheckout(apiStub(), { email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { redirect: 'https://checkout.stripe/x' });
});

test('startCheckout surfaces an error', async () => {
  const api = apiStub({ checkout: async () => ({ ok: false, status: 400, data: { error: 'bad' } }) });
  const r = await startCheckout(api, { email: 'a@b.com', plan: 'yearly' });
  assert.deepEqual(r, { error: 'bad', status: 400 });
});

test('completeCheckout with a device mints a token and returns a deeplink', async () => {
  const api = apiStub({
    sessionFromCheckout: async () => ({ ok: true, status: 200, data: { user: {}, device: 'fp-1', device_name: 'Mac', state: 'n' } }),
  });
  const r = await completeCheckout(api, 'cs_1');
  assert.equal(r.deeplink, 'slipreel://auth?token=jwt&refresh=rt&device_id=dev_1&state=n');
});

test('completeCheckout without a device routes to account', async () => {
  const r = await completeCheckout(apiStub(), 'cs_1');
  assert.deepEqual(r, { account: { email: 'u@e.com', userId: 'user_1' } });
});

test('completeCheckout surfaces a seat-limit 409', async () => {
  const api = apiStub({
    sessionFromCheckout: async () => ({ ok: true, status: 200, data: { user: {}, device: 'fp-9', device_name: null, state: null } }),
    token: async () => ({ ok: false, status: 409, data: { error: 'seat_limit', devices: [{ id: 'd1' }, { id: 'd2' }] } }),
  });
  const r = await completeCheckout(api, 'cs_1');
  assert.deepEqual(r, { seatLimit: [{ id: 'd1' }, { id: 'd2' }] });
});

test('completeMagicLink mirrors completeCheckout (device -> deeplink)', async () => {
  const api = apiStub({
    magicLinkVerify: async () => ({ ok: true, status: 200, data: { user: {}, device: 'fp-2', device_name: 'Air', state: 's' } }),
  });
  const r = await completeMagicLink(api, 'mtok');
  assert.equal(r.deeplink, 'slipreel://auth?token=jwt&refresh=rt&device_id=dev_1&state=s');
});

test('requestMagicLink reports sent', async () => {
  assert.deepEqual(await requestMagicLink(apiStub(), { email: 'a@b.com' }), { sent: true });
});
