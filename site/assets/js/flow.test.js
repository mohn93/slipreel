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

test('pending payment waits before minting activation and preserves activation context', async () => {
  let calls = 0, tokenCalls = 0;
  const result = await completeCheckout(apiStub({
    sessionFromCheckout: async () => ++calls < 3 ? { ok: true, status: 202, data: { error: 'payment_pending' } }
      : { ok: true, status: 200, data: { user: {}, device: 'mac', state: 'nonce' } },
    token: async () => { tokenCalls++; return okToken; },
  }), 'cs', { wait: async () => {} });
  assert.equal(calls, 3);
  assert.equal(tokenCalls, 1);
  assert.ok(result.deeplink.includes('state=nonce'));
});
test('pending payment exhausts bounded retry without issuing any free activation', async () => {
  const result = await completeCheckout(apiStub({
    sessionFromCheckout: async () => ({ ok: true, status: 202, data: {} }),
    token: async () => { assert.fail('must not activate pending purchase'); },
  }), 'cs', { attempts: 2, wait: async () => {} });
  assert.deepEqual(result, { pending: true, sessionId: 'cs' });
});
test('verified checkout intent starts checkout without premature device activation', async () => {
  let posted;
  const result = await completeMagicLink(apiStub({
    magicLinkVerify: async () => ({ ok: true, data: { checkout_plan: 'monthly', device: 'mac', device_name: 'Air', state: 'nonce' } }),
    checkout: async (body) => { posted = body; return { ok: true, data: { url: 'https://checkout.stripe/x' } }; },
    token: async () => assert.fail('must not activate before payment'),
  }), 'magic');
  assert.equal(posted.plan, 'monthly');
  assert.equal(posted.state, 'nonce');
  assert.equal(result.redirect, 'https://checkout.stripe/x');
});
test('verified cancellation resumes only the server-owned flow', async () => {
  const result = await completeMagicLink(apiStub({ magicLinkVerify: async () => ({ ok: true, data: { checkout_flow: 'flow123', checkout_plan: 'monthly' } }) }), 'magic');
  assert.equal(result.redirect, 'pricing.html?flow=flow123');
});
test('checkout failure after verification retains context for retry without consuming the magic link twice', async () => {
  const result = await completeMagicLink(apiStub({
    magicLinkVerify: async () => ({ ok: true, data: { checkout_plan: 'onetime', device: 'mac', state: 'nonce' } }),
    checkout: async () => ({ ok: false, status: 503, data: {} }),
  }), 'magic');
  assert.equal(result.phase, 'checkout');
  assert.equal(result.checkoutContext.device, 'mac');
  assert.equal(result.checkoutContext.state, 'nonce');
});
