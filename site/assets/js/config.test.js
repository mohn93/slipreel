import test from 'node:test';
import assert from 'node:assert/strict';
import { apiBase } from './config.js';

test('apiBase uses the API subdomain in production', () => {
  assert.equal(apiBase('slipreel.app'), 'https://api.slipreel.app');
  assert.equal(apiBase('www.slipreel.app'), 'https://api.slipreel.app');
});

test('apiBase honors an explicit meta override', () => {
  assert.equal(apiBase('localhost', 'http://localhost:8080'), 'http://localhost:8080');
});

test('apiBase falls back to host:8080 in dev', () => {
  assert.equal(apiBase('localhost'), 'http://localhost:8080');
  assert.equal(apiBase('127.0.0.1'), 'http://127.0.0.1:8080');
});
