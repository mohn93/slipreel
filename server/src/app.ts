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
    // Trust X-Forwarded-* only from the co-located nginx on loopback.
    trustProxy: 'loopback',
  });

  app.decorate('pool', deps.pool);
  app.register(healthRoutes);

  return app;
}
