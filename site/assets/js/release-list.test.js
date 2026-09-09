import test from 'node:test';
import assert from 'node:assert/strict';
import { eligibleReleases, safeDownloadUrl, supportedRelease } from './release-list.js';
test('archive only checks first-party release downloads', () => {
  assert.ok(safeDownloadUrl('https://slipreel.app/download/Slipreel-1.0.13.dmg'));
  for (const url of ['https://attacker.example/x.dmg', 'http://slipreel.app/download/x.dmg', 'https://slipreel.app/private/x.dmg', 'javascript:alert(1)']) assert.equal(safeDownloadUrl(url), false);
});
test('license date ceiling excludes newer releases and unknown dates', () => {
  assert.deepEqual(eligibleReleases([{ build: 1000014, date: '2026-09-09T00:00:00Z' }, { build: 1000013, date: '2026-09-08T00:00:00Z' }, { build: 1000015 }], '2026-09-08'), [{ build: 1000013, date: '2026-09-08T00:00:00Z' }]);
});

test('cached appcasts cannot reintroduce withdrawn installers', () => {
  const legacy = Array.from({ length: 13 }, (_, patch) => ({ build: 1000000 + patch, date: '2026-09-07T00:00:00Z' }));
  const supported = { build: '1000013', date: '2026-09-09T00:00:00Z' };
  const future = { build: 1000014, date: '2026-10-01T00:00:00Z' };
  assert.deepEqual(eligibleReleases([...legacy, supported, future], ''), [future, supported]);
  assert.deepEqual(eligibleReleases([...legacy, supported, future], '2026-09-09'), [supported]);
  assert.deepEqual(eligibleReleases([...legacy, supported], '2026-09-08'), []);
  for (const build of [null, '', 'bad', 1000012, 1000013.5]) assert.equal(supportedRelease({ build }), false);
});
