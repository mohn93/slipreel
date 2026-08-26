import { describe, it, expect, afterEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import pg from 'pg';
import { buildApp } from '../src/app.js';

// CORS doesn't need a DB; use a dummy pool that's never queried on these routes.
const pool = new pg.Pool({ connectionString: 'postgres://x:x@localhost:5432/x' });

describe('CORS', () => {
  let app: FastifyInstance;
  afterEach(async () => { if (app) await app.close(); });

  it('reflects an allowed origin with credentials on a preflight', async () => {
    app = buildApp({ pool, corsOrigins: ['https://slipreel.app'], logger: false });
    await app.ready();
    const res = await app.inject({
      method: 'OPTIONS', url: '/health',
      headers: { origin: 'https://slipreel.app', 'access-control-request-method': 'GET' },
    });
    expect(res.headers['access-control-allow-origin']).toBe('https://slipreel.app');
    expect(res.headers['access-control-allow-credentials']).toBe('true');
  });

  it('does not allow a disallowed origin', async () => {
    app = buildApp({ pool, corsOrigins: ['https://slipreel.app'], logger: false });
    await app.ready();
    const res = await app.inject({
      method: 'OPTIONS', url: '/health',
      headers: { origin: 'https://evil.example', 'access-control-request-method': 'GET' },
    });
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });
});
