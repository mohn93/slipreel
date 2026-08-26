import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify';
import rawBody from 'fastify-raw-body';
import cookie from '@fastify/cookie';
import cors from '@fastify/cors';
import type pg from 'pg';
import type Stripe from 'stripe';
import { healthRoutes } from './routes/health.js';
import { stripeWebhookRoutes } from './routes/stripe-webhook.js';
import { billingRoutes } from './routes/billing.js';
import { authRoutes } from './routes/auth.js';
import { magicLinkRoutes } from './routes/magic-link.js';
import { tokenRoutes } from './routes/token.js';
import { deviceRoutes } from './routes/devices.js';
import { entitlementPubkeyRoutes } from './routes/entitlement-pubkey.js';
import type { BillingConfig } from './billing/config.js';
import type { TokenSigner } from './tokens/signer.js';
import type { EmailSender } from './email/sender.js';

declare module 'fastify' {
  interface FastifyInstance {
    pool: pg.Pool;
    stripe: Stripe;
    billing: BillingConfig;
    tokenSigner: TokenSigner;
    email?: EmailSender;
  }
}

export type AppDeps = {
  pool: pg.Pool;
  logger?: FastifyServerOptions['logger'];
  stripe?: Stripe;
  billing?: BillingConfig;
  tokenSigner?: TokenSigner;
  email?: EmailSender;
  corsOrigins?: string[];
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
    logger: deps.logger ?? true,
    // Trust X-Forwarded-* only from the co-located nginx on loopback.
    trustProxy: 'loopback',
  });

  if (deps.corsOrigins && deps.corsOrigins.length > 0) {
    app.register(cors, { origin: deps.corsOrigins, credentials: true });
  }

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

  // Licensing (auth + tokens) is optional: registered only when a token signer
  // is provided (alongside stripe+billing, which session-from-checkout needs).
  if (deps.tokenSigner && deps.stripe && deps.billing) {
    if (deps.email) app.decorate('email', deps.email);
    app.decorate('tokenSigner', deps.tokenSigner);
    app.register(cookie);
    app.register(authRoutes);
    app.register(magicLinkRoutes);
    app.register(tokenRoutes);
    app.register(deviceRoutes);
    app.register(entitlementPubkeyRoutes);
  }

  return app;
}
