import { describe, it, expect } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  const base = {
    NODE_ENV: 'test',
    PORT: '8080',
    LOG_LEVEL: 'info',
    DATABASE_URL: 'postgres://u:p@localhost:5433/db',
  };

  it('parses a valid environment', () => {
    const cfg = loadConfig(base);
    expect(cfg.nodeEnv).toBe('test');
    expect(cfg.port).toBe(8080);
    expect(cfg.databaseUrl).toBe('postgres://u:p@localhost:5433/db');
    expect(cfg.logLevel).toBe('info');
  });

  it('defaults PORT and LOG_LEVEL when absent', () => {
    const cfg = loadConfig({ NODE_ENV: 'development', DATABASE_URL: base.DATABASE_URL });
    expect(cfg.port).toBe(8080);
    expect(cfg.logLevel).toBe('info');
    expect(cfg.nodeEnv).toBe('development');
  });

  it('throws when DATABASE_URL is missing', () => {
    expect(() => loadConfig({ NODE_ENV: 'test' })).toThrow(/DATABASE_URL/);
  });

  it('throws when PORT is not a number', () => {
    expect(() => loadConfig({ ...base, PORT: 'abc' })).toThrow(/PORT/);
  });
});
