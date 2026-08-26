import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify';
import rawBody from 'fastify-raw-body';
import type pg from 'pg';
import type Stripe from 'stripe';
import { healthRoutes } from './routes/health.js';
import { stripeWebhookRoutes } from './routes/stripe-webhook.js';
import { billingRoutes } from './routes/billing.js';
import type { BillingConfig } from './billing/config.js';

declare module 'fastify' {
  interface FastifyInstance {
    pool: pg.Pool;
    stripe: Stripe;
    billing: BillingConfig;
  }
}

export type AppDeps = {
  pool: pg.Pool;
  logger?: FastifyServerOptions['logger'];
  stripe?: Stripe;
  billing?: BillingConfig;
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
    logger: deps.logger ?? true,
    // Trust X-Forwarded-* only from the co-located nginx on loopback.
    trustProxy: 'loopback',
  });

  app.decorate('pool', deps.pool);
  app.register(healthRoutes);

  // Billing is optional: with no stripe client + config the app is Phase-1
  // behaviour (only /health), so keyless dev and existing tests still work.
  if (deps.stripe && deps.billing) {
    app.decorate('stripe', deps.stripe);
    app.decorate('billing', deps.billing);
    // Raw body needed so the webhook can verify Stripe's signature over bytes.
    app.register(rawBody, { field: 'rawBody', global: false, encoding: 'utf8', runFirst: true });
    app.register(stripeWebhookRoutes);
    app.register(billingRoutes);
  }

  return app;
}
