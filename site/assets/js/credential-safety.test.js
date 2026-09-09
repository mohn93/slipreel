import test from 'node:test';
import assert from 'node:assert/strict';
import { redactUrl, scrubEvent, consumeCredentialParams } from './credential-safety.js';
test('credentials in URL, referrer and callback attributes never survive analytics scrubbing', () => {
  const event = scrubEvent({ properties: {
    $current_url: 'https://slipreel.app/login?token=SECRET&plan=monthly#private',
    $referrer: 'https://slipreel.app/success?session_id=SECRET',
    nested: { href: 'slipreel://auth?token=SECRET&refresh=SECRET', refresh_token: 'SECRET' },
  } });
  assert.ok(!JSON.stringify(event).includes('SECRET'));
  assert.equal(event.properties.$current_url, 'https://slipreel.app/login?plan=monthly');
  assert.equal(redactUrl('slipreel://auth?token=a'), '[app callback]');
});
test('credential params are available to flow but removed from browser history', () => {
  let replacement;
  const params = consumeCredentialParams({ pathname: '/login', search: '?token=secret&state=nonce&plan=monthly' }, { replaceState: (...args) => { replacement = args; } });
  assert.equal(params.get('token'), 'secret');
  assert.deepEqual(replacement, [null, '', '/login?plan=monthly']);
});
