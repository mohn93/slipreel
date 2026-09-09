import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { scrubEvent } from './credential-safety.js';
const source = readFileSync(new URL('./analytics.js', import.meta.url), 'utf8').replace(/^import .*;$/gm, '');
function environment(pathname) {
  let idle, config, identified;
  const window = {
    location: { origin: 'https://slipreel.app' },
    requestIdleCallback: (callback) => { idle = callback; },
    posthog: { __SV: 1, init: (_key, options) => { config = options; }, identify: (...args) => { identified = args; } },
  };
  vm.runInNewContext(source, { window, location: { pathname }, document: {}, POSTHOG_KEY: 'phc_fixture', scrubEvent });
  return { window, start: () => idle?.(), loaded: () => { window.posthog.__loaded = true; config.loaded(window.posthog); }, config: () => config, identified: () => identified };
}
test('identity queued before SDK readiness is applied on loaded callback', () => {
  const env = environment('/');
  env.window.slipreelIdentify('fixture-user', { fixture: true });
  env.start();
  assert.equal(env.identified(), undefined);
  env.loaded();
  assert.deepEqual(env.identified(), ['fixture-user', { fixture: true }]);
  assert.equal(env.config().disable_session_recording, true);
  assert.equal(typeof env.config().before_send, 'function');
});
test('credential and account pages never initialize analytics even if module is accidentally loaded', () => {
  for (const route of ['/login', '/success.html', '/cancel', '/cancel.html', '/account', '/pricing.html']) {
    const env = environment(route);
    env.start();
    assert.equal(env.config(), undefined);
  }
  for (const page of ['login', 'success', 'cancel', 'account', 'pricing']) {
    const html = readFileSync(new URL(`../../${page}.html`, import.meta.url), 'utf8');
    assert.ok(!html.includes('src="assets/js/analytics.js'));
    assert.ok(html.includes('name="referrer" content="no-referrer"'));
  }
});

test('analytics preserves only its configured public ingestion key after credential redaction', () => {
  const env = environment('/');
  env.start();
  const hook = env.config().before_send;
  const original = { event: '$pageview', timestamp: new Date('2026-09-09T15:00:00Z'), properties: {
    token: 'AUTH_SECRET',
    $current_url: 'https://slipreel.app/?token=URL_SECRET&plan=monthly',
    nested: { token: 'NESTED_SECRET', refresh_token: 'REFRESH_SECRET' },
  } };
  const clean = hook(original);
  assert.equal(clean.properties.token, 'phc_fixture');
  assert.ok(clean.timestamp instanceof Date);
  assert.equal(JSON.parse(JSON.stringify(clean)).timestamp, '2026-09-09T15:00:00.000Z');
  assert.equal(clean.properties.$current_url, 'https://slipreel.app/?plan=monthly');
  assert.ok(!JSON.stringify(clean).includes('SECRET'));
  assert.equal(original.properties.token, 'AUTH_SECRET');
  assert.equal(hook(null), null);
});
