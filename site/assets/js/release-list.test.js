import test from 'node:test';
import assert from 'node:assert/strict';
import { eligibleReleases, safeDownloadUrl } from './release-list.js';
test('archive only checks first-party release downloads', () => {
  assert.ok(safeDownloadUrl('https://slipreel.app/download/Slipreel-1.0.12.dmg'));
  for (const url of ['https://attacker.example/x.dmg', 'http://slipreel.app/download/x.dmg', 'https://slipreel.app/private/x.dmg', 'javascript:alert(1)']) assert.equal(safeDownloadUrl(url), false);
});
test('license date ceiling excludes newer releases and unknown dates', () => {
  assert.deepEqual(eligibleReleases([{ build: 2, date: '2026-09-09T00:00:00Z' }, { build: 1, date: '2026-09-08T00:00:00Z' }, { build: 3 }], '2026-09-08'), [{ build: 1, date: '2026-09-08T00:00:00Z' }]);
});
