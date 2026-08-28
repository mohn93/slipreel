import { describe, it, expect } from 'vitest';
import { newId } from '../src/ids.js';

describe('newId', () => {
  it('prefixes and produces 32 hex chars', () => {
    const id = newId('usr');
    expect(id).toMatch(/^usr_[0-9a-f]{32}$/);
  });

  it('is unique across calls', () => {
    const a = newId('dev');
    const b = newId('dev');
    expect(a).not.toBe(b);
  });
});
