# VPS API Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a tested, runnable Node/TypeScript + Postgres API service (`server/`) with config, DB pool, SQL migrations, a health endpoint, structured logging, graceful shutdown, and systemd/nginx deploy artifacts — the foundation the Stripe, entitlement-token, and account features build on.

**Architecture:** A Fastify (v5) HTTP service written in TypeScript (ESM), talking to Postgres via `pg`. Config is parsed and validated from environment with zod. Schema changes are plain SQL files applied by a small in-house idempotent migration runner recorded in a `schema_migrations` table. Everything is unit/integration tested with vitest; DB-backed tests run against a Dockerized Postgres. The service is deployed on the existing VPS as a systemd unit behind nginx at `api.slipreel.app`.

**Tech Stack:** Node 22, TypeScript (ESM, `NodeNext`), Fastify 5, `pg` (node-postgres), zod, vitest, Docker Compose (Postgres 16), pino (Fastify built-in) logging, systemd + nginx.

**Spec:** [docs/superpowers/specs/2026-08-26-stripe-licensing-design.md](../specs/2026-08-26-stripe-licensing-design.md)

## Global Constraints

- **Location:** all backend code lives under `server/` at the repo root; it is NOT a melos/Dart package.
- **Language/module system:** TypeScript, ESM (`"type": "module"`, `moduleResolution: "NodeNext"`). No CommonJS `require`.
- **Node version:** Node 22 (`engines.node >= 22`).
- **Framework:** Fastify 5. **DB client:** `pg`. **Validation:** `zod`. **Tests:** `vitest`.
- **Secrets:** every secret (DB URL, later Stripe keys, Ed25519 private key) comes from environment only, never committed. `.env` and `server/.env` are gitignored.
- **Migrations:** forward-only SQL files `server/migrations/NNNN_<name>.sql`, applied in filename order, tracked in `schema_migrations`. Never edit an already-applied migration; add a new one.
- **DB identity:** Postgres 16; the schema uses the `citext` extension. Tests run against real Postgres (Docker), not an emulator.
- **Public base URL:** `https://api.slipreel.app` (reverse-proxied to `127.0.0.1:${PORT}`, default `PORT=8080`).
- **Git:** work on branch `feat/stripe-licensing`. Stage only files you created/changed (no `git add -A`).

---

## File Structure

```
server/
  package.json            # scripts, deps, engines, ESM
  tsconfig.json           # strict, NodeNext, outDir dist/
  vitest.config.ts        # test config
  docker-compose.yml      # Postgres 16 for dev + tests
  .env.example            # documented env template (committed)
  initdb.d/
    01-create-test-db.sql # creates slipreel_test alongside slipreel
  migrations/
    0001_init.sql         # users, entitlements, devices, processed_stripe_events
  src/
    config.ts             # loadConfig(env) -> Config (zod-validated)
    db.ts                 # createPool(config) -> pg.Pool
    migrate.ts            # runMigrations(pool, dir) idempotent runner
    app.ts                # buildApp({ pool, logger? }) -> FastifyInstance (routes)
    server.ts             # entrypoint: config -> pool -> migrate -> listen -> shutdown
    routes/
      health.ts           # GET /health (checks DB connectivity)
  test/
    config.test.ts        # pure config parsing (no DB)
    migrate.test.ts       # migration runner + schema (DB)
    health.test.ts        # GET /health via fastify.inject (DB)
    helpers/
      testDb.ts           # TEST_DATABASE_URL pool + reset helper
  deploy/
    slipreel-api.service  # systemd unit
    nginx-api.conf        # nginx server block for api.slipreel.app
  README.md               # setup / dev / test / build / deploy
```

Responsibilities are one-per-file: `config.ts` only parses env; `db.ts` only builds a pool; `migrate.ts` only applies SQL; `app.ts` only wires Fastify + routes (no `listen`); `server.ts` is the only place that has side effects (connect, migrate, listen). This keeps `app.ts` fully testable via `fastify.inject` with an injected pool.

---

### Task 1: Project scaffold + validated config

Establishes the `server/` project, toolchain, gitignore rules, and a pure, unit-tested config loader. Deliverable: `npm --prefix server test` runs and the config tests pass (no DB needed).

**Files:**
- Create: `server/package.json`
- Create: `server/tsconfig.json`
- Create: `server/vitest.config.ts`
- Create: `server/.env.example`
- Create: `server/src/config.ts`
- Create: `server/test/config.test.ts`
- Modify: `.gitignore` (repo root — add Node/env ignores)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type Config = { nodeEnv: 'development' | 'test' | 'production'; port: number; databaseUrl: string; logLevel: 'fatal'|'error'|'warn'|'info'|'debug'|'trace'|'silent' }`
  - `function loadConfig(env: NodeJS.ProcessEnv = process.env): Config` — throws `Error` with a readable message listing invalid/missing vars.

- [ ] **Step 1: Add root gitignore rules**

Append to `.gitignore` at the repo root:

```gitignore

# Node backend (server/)
server/node_modules/
server/dist/
.env
.env.*
!.env.example
server/.env
server/.env.*
!server/.env.example
```

- [ ] **Step 2: Create `server/package.json`**

```json
{
  "name": "slipreel-api",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/server.js",
    "dev": "tsx watch src/server.ts",
    "migrate": "tsx src/migrate-cli.ts",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "db:up": "docker compose up -d",
    "db:down": "docker compose down"
  },
  "dependencies": {
    "fastify": "^5.2.0",
    "pg": "^8.13.1",
    "zod": "^3.24.1"
  },
  "devDependencies": {
    "@types/node": "^22.10.0",
    "@types/pg": "^8.11.10",
    "tsx": "^4.19.2",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  }
}
```

Note: `migrate-cli.ts` is created in Task 3; the `migrate` script is declared here so `package.json` isn't touched again.

- [ ] **Step 3: Create `server/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2023"],
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": false,
    "sourceMap": true,
    "resolveJsonModule": true
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist", "test"]
}
```

- [ ] **Step 4: Create `server/vitest.config.ts`**

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
    // DB-backed tests run serially to avoid cross-test schema races.
    fileParallelism: false,
    hookTimeout: 30_000,
    testTimeout: 30_000,
  },
});
```

- [ ] **Step 5: Create `server/.env.example`**

```dotenv
# Runtime environment: development | test | production
NODE_ENV=development
# Port the Fastify server listens on (nginx reverse-proxies to this)
PORT=8080
# Log level: fatal|error|warn|info|debug|trace|silent
LOG_LEVEL=info
# Postgres connection string (dev DB from docker-compose)
DATABASE_URL=postgres://slipreel:slipreel@localhost:5433/slipreel
# Separate database used by the vitest DB-backed tests
TEST_DATABASE_URL=postgres://slipreel:slipreel@localhost:5433/slipreel_test
```

- [ ] **Step 6: Write the failing test `server/test/config.test.ts`**

```ts
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
```

- [ ] **Step 7: Run the test to verify it fails**

Run: `npm --prefix server install && npm --prefix server test -- config`
Expected: FAIL — `loadConfig` cannot be imported (module `../src/config.js` not found).

- [ ] **Step 8: Implement `server/src/config.ts`**

```ts
import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(8080),
  LOG_LEVEL: z
    .enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'])
    .default('info'),
  DATABASE_URL: z.string().min(1, 'DATABASE_URL is required'),
});

export type Config = {
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  databaseUrl: string;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'silent';
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid environment configuration: ${issues}`);
  }
  const e = parsed.data;
  return {
    nodeEnv: e.NODE_ENV,
    port: e.PORT,
    databaseUrl: e.DATABASE_URL,
    logLevel: e.LOG_LEVEL,
  };
}
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `npm --prefix server test -- config`
Expected: PASS (4 tests).

- [ ] **Step 10: Commit**

```bash
git add .gitignore server/package.json server/package-lock.json server/tsconfig.json \
  server/vitest.config.ts server/.env.example server/src/config.ts server/test/config.test.ts
git commit -m "feat(server): scaffold Node/TS API with validated config"
```

---

### Task 2: Dockerized Postgres + test DB helper

Provides the Postgres the DB-backed tests and local dev need, plus a reusable test-pool helper. Deliverable: `docker compose up -d` brings up Postgres with both `slipreel` and `slipreel_test` databases, and the helper can connect.

**Files:**
- Create: `server/docker-compose.yml`
- Create: `server/initdb.d/01-create-test-db.sql`
- Create: `server/src/db.ts`
- Create: `server/test/helpers/testDb.ts`

**Interfaces:**
- Consumes: `Config` from Task 1.
- Produces:
  - `function createPool(config: Config): pg.Pool` (in `db.ts`).
  - `function testPool(): pg.Pool` — a `pg.Pool` bound to `TEST_DATABASE_URL` (throws if unset).
  - `async function resetDatabase(pool: pg.Pool): Promise<void>` — drops and recreates the `public` schema so each test file starts clean.

- [ ] **Step 1: Create `server/docker-compose.yml`**

```yaml
services:
  db:
    image: postgres:16
    container_name: slipreel-db
    environment:
      POSTGRES_USER: slipreel
      POSTGRES_PASSWORD: slipreel
      POSTGRES_DB: slipreel
    ports:
      - "5433:5432"
    volumes:
      - slipreel_pgdata:/var/lib/postgresql/data
      - ./initdb.d:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U slipreel -d slipreel"]
      interval: 3s
      timeout: 3s
      retries: 10

volumes:
  slipreel_pgdata:
```

- [ ] **Step 2: Create `server/initdb.d/01-create-test-db.sql`**

This runs only on first container init (empty data dir). It creates the separate test database.

```sql
CREATE DATABASE slipreel_test OWNER slipreel;
```

- [ ] **Step 3: Bring up the database**

Run: `npm --prefix server run db:up`
Then verify: `docker exec slipreel-db psql -U slipreel -d slipreel_test -c 'select 1'`
Expected: a `1` row prints. (If `slipreel_test` is missing because the volume predates the init script, run `docker exec slipreel-db psql -U slipreel -d slipreel -c 'CREATE DATABASE slipreel_test OWNER slipreel;'`.)

- [ ] **Step 4: Implement `server/src/db.ts`**

```ts
import pg from 'pg';
import type { Config } from './config.js';

export function createPool(config: Config): pg.Pool {
  return new pg.Pool({ connectionString: config.databaseUrl, max: 10 });
}
```

- [ ] **Step 5: Implement `server/test/helpers/testDb.ts`**

```ts
import pg from 'pg';

export function testPool(): pg.Pool {
  const url = process.env.TEST_DATABASE_URL;
  if (!url) {
    throw new Error(
      'TEST_DATABASE_URL is not set. Copy server/.env.example to server/.env ' +
        'and run `npm run db:up` (see server/README.md).',
    );
  }
  return new pg.Pool({ connectionString: url, max: 4 });
}

/** Drop and recreate the public schema so a test file starts from empty. */
export async function resetDatabase(pool: pg.Pool): Promise<void> {
  await pool.query('DROP SCHEMA IF EXISTS public CASCADE');
  await pool.query('CREATE SCHEMA public');
}
```

- [ ] **Step 6: Smoke-check the helper compiles/type-checks**

Run: `npm --prefix server run typecheck`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add server/docker-compose.yml server/initdb.d/01-create-test-db.sql \
  server/src/db.ts server/test/helpers/testDb.ts
git commit -m "feat(server): dockerized Postgres and test DB helpers"
```

Note: DB-backed tests in later tasks require `TEST_DATABASE_URL` in the environment. Load it from `server/.env` by running tests as `env $(grep -v '^#' server/.env | xargs) npm --prefix server test`, or export the var in your shell. The README (Task 6) documents this.

---

### Task 3: Migration runner + initial schema

A small idempotent SQL migration runner and the first migration creating the four tables from the spec. Deliverable: an integration test proves migrations apply, are idempotent, and produce the expected tables.

**Files:**
- Create: `server/src/migrate.ts`
- Create: `server/src/migrate-cli.ts`
- Create: `server/migrations/0001_init.sql`
- Create: `server/test/migrate.test.ts`

**Interfaces:**
- Consumes: `pg.Pool`; `testPool`, `resetDatabase` from Task 2.
- Produces:
  - `async function runMigrations(pool: pg.Pool, dir?: string): Promise<string[]>` — applies pending `NNNN_*.sql` files in order inside a transaction each, records them in `schema_migrations`, and returns the list of filenames newly applied (empty when up to date).

- [ ] **Step 1: Write `server/migrations/0001_init.sql`**

```sql
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE users (
  id                 text PRIMARY KEY,
  email              citext UNIQUE NOT NULL,
  password_hash      text NOT NULL,
  email_verified     boolean NOT NULL DEFAULT false,
  stripe_customer_id text UNIQUE,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE entitlements (
  id                       text PRIMARY KEY,
  user_id                  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan                     text NOT NULL CHECK (plan IN ('subscription', 'onetime')),
  status                   text NOT NULL CHECK (status IN ('active', 'grace', 'canceled', 'incomplete')),
  stripe_subscription_id   text,
  stripe_payment_intent_id text,
  current_period_end       timestamptz,
  updates_until            timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX entitlements_user_id_idx ON entitlements(user_id);

CREATE TABLE devices (
  id                 text PRIMARY KEY,
  user_id            text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fingerprint        text NOT NULL,
  name               text,
  refresh_token_hash text NOT NULL,
  last_seen_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, fingerprint)
);

CREATE TABLE processed_stripe_events (
  event_id     text PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT now()
);
```

- [ ] **Step 2: Write the failing test `server/test/migrate.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';

describe('runMigrations', () => {
  let pool: pg.Pool;

  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
  });

  afterAll(async () => {
    await pool.end();
  });

  it('applies the initial migration and creates the expected tables', async () => {
    const applied = await runMigrations(pool);
    expect(applied).toContain('0001_init.sql');

    const { rows } = await pool.query<{ table_name: string }>(
      `SELECT table_name FROM information_schema.tables
       WHERE table_schema = 'public' ORDER BY table_name`,
    );
    const names = rows.map((r) => r.table_name);
    expect(names).toEqual(
      expect.arrayContaining([
        'users',
        'entitlements',
        'devices',
        'processed_stripe_events',
        'schema_migrations',
      ]),
    );
  });

  it('is idempotent — a second run applies nothing', async () => {
    const applied = await runMigrations(pool);
    expect(applied).toEqual([]);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- migrate`
Expected: FAIL — cannot import `../src/migrate.js`.

- [ ] **Step 4: Implement `server/src/migrate.ts`**

```ts
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import type pg from 'pg';

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

const MIGRATION_FILE = /^\d{4}_.+\.sql$/;

export async function runMigrations(
  pool: pg.Pool,
  dir: string = MIGRATIONS_DIR,
): Promise<string[]> {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
       filename    text PRIMARY KEY,
       applied_at  timestamptz NOT NULL DEFAULT now()
     )`,
  );

  const files = (await readdir(dir))
    .filter((f) => MIGRATION_FILE.test(f))
    .sort();

  const { rows } = await pool.query<{ filename: string }>(
    'SELECT filename FROM schema_migrations',
  );
  const done = new Set(rows.map((r) => r.filename));

  const applied: string[] = [];
  for (const file of files) {
    if (done.has(file)) continue;
    const sql = await readFile(join(dir, file), 'utf8');
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [file]);
      await client.query('COMMIT');
      applied.push(file);
    } catch (err) {
      await client.query('ROLLBACK');
      throw new Error(`Migration ${file} failed: ${(err as Error).message}`);
    } finally {
      client.release();
    }
  }
  return applied;
}
```

- [ ] **Step 5: Implement `server/src/migrate-cli.ts`** (the `npm run migrate` entrypoint)

```ts
import { loadConfig } from './config.js';
import { createPool } from './db.js';
import { runMigrations } from './migrate.js';

const pool = createPool(loadConfig());
try {
  const applied = await runMigrations(pool);
  console.log(applied.length ? `Applied: ${applied.join(', ')}` : 'Already up to date.');
} catch (err) {
  console.error((err as Error).message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- migrate`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add server/src/migrate.ts server/src/migrate-cli.ts server/migrations/0001_init.sql \
  server/test/migrate.test.ts
git commit -m "feat(server): idempotent SQL migration runner and initial schema"
```

---

### Task 4: Fastify app + health endpoint

Wires the Fastify instance and a `/health` route that reports DB connectivity. `buildApp` takes an injected pool so it is testable without a live listener. Deliverable: an inject-based test proves `/health` returns 200 + `db: 'up'` against the test DB.

**Files:**
- Create: `server/src/app.ts`
- Create: `server/src/routes/health.ts`
- Create: `server/test/health.test.ts`

**Interfaces:**
- Consumes: `pg.Pool`.
- Produces:
  - `type AppDeps = { pool: pg.Pool; logger?: FastifyServerOptions['logger'] }`
  - `function buildApp(deps: AppDeps): FastifyInstance` — a fully configured, not-yet-listening Fastify instance with routes registered and `app.pool` decorated.
  - Route: `GET /health` → `200 { status: 'ok', db: 'up' }`, or `503 { status: 'degraded', db: 'down' }` if the DB query throws.

- [ ] **Step 1: Write the failing test `server/test/health.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { buildApp } from '../src/app.js';

describe('GET /health', () => {
  let pool: pg.Pool;
  let app: FastifyInstance;

  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
    await runMigrations(pool);
    app = buildApp({ pool, logger: false });
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
    await pool.end();
  });

  it('returns 200 and db: up when the database is reachable', async () => {
    const res = await app.inject({ method: 'GET', url: '/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: 'ok', db: 'up' });
  });

  it('returns 404 for unknown routes', async () => {
    const res = await app.inject({ method: 'GET', url: '/nope' });
    expect(res.statusCode).toBe(404);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- health`
Expected: FAIL — cannot import `../src/app.js`.

- [ ] **Step 3: Implement `server/src/routes/health.ts`**

```ts
import type { FastifyInstance } from 'fastify';

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get('/health', async (_req, reply) => {
    try {
      await app.pool.query('SELECT 1');
      return { status: 'ok', db: 'up' };
    } catch (err) {
      app.log.error({ err }, 'health check DB query failed');
      return reply.code(503).send({ status: 'degraded', db: 'down' });
    }
  });
}
```

- [ ] **Step 4: Implement `server/src/app.ts`**

```ts
import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify';
import type pg from 'pg';
import { healthRoutes } from './routes/health.js';

declare module 'fastify' {
  interface FastifyInstance {
    pool: pg.Pool;
  }
}

export type AppDeps = {
  pool: pg.Pool;
  logger?: FastifyServerOptions['logger'];
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
    logger: deps.logger ?? true,
    // Trust the nginx reverse proxy for correct client IPs / protocol.
    trustProxy: true,
  });

  app.decorate('pool', deps.pool);
  app.register(healthRoutes);

  return app;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- health`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the full suite + typecheck**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test && npm --prefix server run typecheck`
Expected: all tests pass, no type errors.

- [ ] **Step 7: Commit**

```bash
git add server/src/app.ts server/src/routes/health.ts server/test/health.test.ts
git commit -m "feat(server): Fastify app with DB-backed health endpoint"
```

---

### Task 5: Server entrypoint with migrate-on-boot + graceful shutdown

The single side-effectful module: load config, build the pool, run migrations, start listening, and shut down cleanly on SIGTERM/SIGINT. Deliverable: `npm run build` compiles and `node dist/server.js` boots against the dev DB and serves `/health`.

**Files:**
- Create: `server/src/server.ts`

**Interfaces:**
- Consumes: `loadConfig`, `createPool`, `runMigrations`, `buildApp`.
- Produces: an executable entrypoint (`dist/server.js`). No exported API.

- [ ] **Step 1: Implement `server/src/server.ts`**

```ts
import { loadConfig } from './config.js';
import { createPool } from './db.js';
import { runMigrations } from './migrate.js';
import { buildApp } from './app.js';

const config = loadConfig();
const pool = createPool(config);

const app = buildApp({
  pool,
  logger: { level: config.logLevel },
});

async function start(): Promise<void> {
  const applied = await runMigrations(pool);
  if (applied.length) app.log.info({ applied }, 'applied migrations');

  await app.listen({ port: config.port, host: '0.0.0.0' });

  for (const signal of ['SIGTERM', 'SIGINT'] as const) {
    process.once(signal, () => {
      app.log.info({ signal }, 'shutting down');
      app
        .close()
        .then(() => pool.end())
        .then(() => process.exit(0))
        .catch((err) => {
          app.log.error({ err }, 'error during shutdown');
          process.exit(1);
        });
    });
  }
}

start().catch((err) => {
  app.log.error({ err }, 'failed to start');
  process.exit(1);
});
```

- [ ] **Step 2: Build the project**

Run: `npm --prefix server run build`
Expected: `server/dist/server.js` and friends exist, no compile errors.

- [ ] **Step 3: Boot the server against the dev DB and hit /health**

Ensure the dev DB is up (`npm --prefix server run db:up`), then in one shell:

```bash
env $(grep -v '^#' server/.env | xargs) node server/dist/server.js
```

In another shell:

```bash
curl -s localhost:8080/health
```

Expected: `{"status":"ok","db":"up"}`. Stop the server with Ctrl-C; logs show `shutting down`. (This is a manual verification step — no automated test for the listening socket.)

- [ ] **Step 4: Commit**

```bash
git add server/src/server.ts
git commit -m "feat(server): entrypoint with migrate-on-boot and graceful shutdown"
```

---

### Task 6: Deploy artifacts + README

The systemd unit, nginx server block for `api.slipreel.app`, and a README covering setup/dev/test/build/deploy. Deliverable: documented, review-ready deployment configuration (no code test cycle; validated by review + a syntax check of the unit file).

**Files:**
- Create: `server/deploy/slipreel-api.service`
- Create: `server/deploy/nginx-api.conf`
- Create: `server/README.md`

**Interfaces:** none (configuration + docs).

- [ ] **Step 1: Create `server/deploy/slipreel-api.service`**

```ini
[Unit]
Description=Slipreel API
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=slipreel-api
Group=slipreel-api
WorkingDirectory=/opt/slipreel-api
# Secrets and DATABASE_URL live here, root-owned 0600, never in git.
EnvironmentFile=/etc/slipreel-api.env
ExecStart=/usr/bin/node /opt/slipreel-api/dist/server.js
Restart=always
RestartSec=2
# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/slipreel-api

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Create `server/deploy/nginx-api.conf`**

```nginx
# api.slipreel.app -> Fastify on 127.0.0.1:8080
# TLS certs provisioned by certbot (certbot --nginx -d api.slipreel.app).
server {
    listen 80;
    listen [::]:80;
    server_name api.slipreel.app;
    # certbot inserts the 443 server block + redirects on first run.

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }

    # NOTE (future Stripe phase): the webhook route must receive the RAW request
    # body for signature verification. nginx forwards the body untouched, so no
    # special config is needed here; the Fastify side must avoid re-parsing it.
}
```

- [ ] **Step 3: Create `server/README.md`**

````markdown
# Slipreel API

Node/TypeScript + Postgres service behind nginx at `https://api.slipreel.app`.
Owns accounts, Stripe checkout/webhooks, device seats, and Ed25519 entitlement
tokens. This package is the Phase 1 skeleton (config, DB, migrations, health).

## Requirements
- Node 22+
- Docker (for local Postgres)

## Setup
```bash
cp .env.example .env
npm install
npm run db:up          # starts Postgres 16 on localhost:5433 (dbs: slipreel, slipreel_test)
```

## Develop
```bash
npm run dev            # tsx watch, migrates on boot, serves /health
curl localhost:8080/health
```

## Test
DB-backed tests need `TEST_DATABASE_URL` (in `.env`). Load it inline:
```bash
env $(grep -v '^#' .env | xargs) npm test
```

## Migrations
Add `migrations/NNNN_<name>.sql` (forward-only; never edit an applied file).
Apply manually with `env $(grep -v '^#' .env | xargs) npm run migrate`; the server
also migrates on boot.

## Build & run
```bash
npm run build && node dist/server.js
```

## Deploy (VPS)
- App dir: `/opt/slipreel-api` (built `dist/` + `node_modules` + `migrations/`).
- Secrets: `/etc/slipreel-api.env` (root-owned, `0600`) with `NODE_ENV=production`,
  `PORT=8080`, `DATABASE_URL=...`, `LOG_LEVEL=info`.
- systemd: install `deploy/slipreel-api.service` to `/etc/systemd/system/`, then
  `systemctl daemon-reload && systemctl enable --now slipreel-api`.
- nginx: install `deploy/nginx-api.conf` to `/etc/nginx/sites-available/`, symlink
  into `sites-enabled/`, then `certbot --nginx -d api.slipreel.app` and
  `nginx -t && systemctl reload nginx`.
- Postgres: create the `slipreel` role + database on the box; point `DATABASE_URL`
  at it. Requires the `citext` extension (migration `0001` enables it).

## Env vars
See `.env.example`. `DATABASE_URL` is required; `PORT` (8080) and `LOG_LEVEL`
(info) have defaults.
````

- [ ] **Step 4: Sanity-check the systemd unit syntax (best-effort)**

Run: `systemd-analyze verify server/deploy/slipreel-api.service 2>&1 || echo '(systemd-analyze unavailable on macOS — review the unit by hand)'`
Expected: either clean output, or the fallback message (the tool isn't on macOS; the unit is reviewed manually).

- [ ] **Step 5: Commit**

```bash
git add server/deploy/slipreel-api.service server/deploy/nginx-api.conf server/README.md
git commit -m "docs(server): systemd unit, nginx config, and README"
```

---

## Self-Review

**Spec coverage (Phase 1 scope only — "VPS API skeleton: Node/TS + Postgres, migrations, health check, systemd/nginx"):**
- Node/TS project → Task 1. Postgres + pool → Tasks 1–2. Migrations + schema (spec §6 tables) → Task 3. Health check → Task 4. Entrypoint/runtime → Task 5. systemd/nginx (spec §3) → Task 6. The four spec §6 tables (`users`, `entitlements`, `devices`, `processed_stripe_events`) are all created verbatim in `0001_init.sql`. Stripe endpoints, entitlement-token minting, auth, and web pages are explicitly OUT of scope here (later phases per spec §14).

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every step has concrete code or an exact command. The only forward-reference is the `migrate` script in `package.json` pointing at `migrate-cli.ts` (created in Task 3) and the webhook-raw-body note in nginx (a comment for a later phase, not a gap in this plan).

**Type consistency:** `Config` shape is identical across `config.ts`, `db.ts`, and its consumers. `runMigrations(pool, dir?)` signature matches every call site (test, CLI, server). `buildApp({ pool, logger })` matches its two call sites (`health.test.ts`, `server.ts`). `app.pool` decoration is declared once (`app.ts`) and used in `routes/health.ts`. DB table/column names in `0001_init.sql` match spec §6.

---

## Execution Handoff

Choose how to execute — see the offer in chat.
