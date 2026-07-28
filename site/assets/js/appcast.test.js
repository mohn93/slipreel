import test from 'node:test';
import assert from 'node:assert/strict';
import { formatBytes, pickLatestItem, itemsFromDocument } from './appcast.js';

test('formatBytes renders megabytes', () => {
  assert.equal(formatBytes(140703903), '141 MB');
});

test('formatBytes rejects junk', () => {
  assert.equal(formatBytes(0), null);
  assert.equal(formatBytes(-5), null);
  assert.equal(formatBytes('abc'), null);
  assert.equal(formatBytes(undefined), null);
});

test('pickLatestItem picks the highest build, not document order', () => {
  const items = [
    { url: 'a.dmg', build: '1000000' },
    { url: 'c.dmg', build: '1000002' },
    { url: 'b.dmg', build: '1000001' },
  ];
  assert.equal(pickLatestItem(items).url, 'c.dmg');
});

test('pickLatestItem ignores items with no url or no build', () => {
  const items = [
    { url: null, build: '9999999' },
    { url: 'real.dmg', build: '1000001' },
    { url: 'nobuild.dmg', build: null },
  ];
  assert.equal(pickLatestItem(items).url, 'real.dmg');
});

test('pickLatestItem returns null when nothing is usable', () => {
  assert.equal(pickLatestItem([]), null);
  assert.equal(pickLatestItem([{ url: null, build: null }]), null);
});

// Minimal stand-in for the parts of the DOM the parser touches.
function fakeDoc(items) {
  const el = (tag, text, attrs) => ({
    tagName: tag,
    textContent: text,
    getAttribute: (k) => (attrs && k in attrs ? attrs[k] : null),
  });
  const nodes = items.map((it) => {
    const kids = [];
    if (it.url !== undefined) {
      kids.push(el('enclosure', '', { url: it.url, length: it.length ?? null }));
    }
    if (it.version !== undefined) kids.push(el('sparkle:shortVersionString', it.version));
    if (it.build !== undefined) kids.push(el('sparkle:version', it.build));
    return {
      getElementsByTagName: (t) => kids.filter((k) => k.tagName === t),
    };
  });
  return { getElementsByTagName: (t) => (t === 'item' ? nodes : []) };
}

test('itemsFromDocument reads url, length, version and build', () => {
  const doc = fakeDoc([
    { url: 'https://slipreel.app/download/Slipreel-1.0.1.dmg', length: '140703903', version: '1.0.1', build: '1000001' },
  ]);
  assert.deepEqual(itemsFromDocument(doc), [
    { url: 'https://slipreel.app/download/Slipreel-1.0.1.dmg', length: '140703903', version: '1.0.1', build: '1000001' },
  ]);
});

test('itemsFromDocument tolerates a malformed item', () => {
  const doc = fakeDoc([{}]);
  assert.deepEqual(itemsFromDocument(doc), [
    { url: null, length: null, version: null, build: null },
  ]);
});
