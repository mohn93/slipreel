import { loadConfig } from './config.js';
import { createPool } from './db.js';
import { runMigrations } from './migrate.js';
import { buildApp } from './app.js';
import { loadBillingConfig } from './billing/config.js';
import { createStripeClient } from './billing/stripe.js';
import { loadTokenConfig } from './tokens/config.js';
import { createTokenSigner } from './tokens/signer.js';
import { loadEmailConfig } from './email/config.js';
import { createResendSender } from './email/resend.js';

const config = loadConfig();
const pool = createPool(config);

// Billing is optional at boot: if the Stripe env isn't set, start without the
// billing routes (only /health etc.) rather than crashing. This keeps a keyless
// dev box working while a fully-configured box gets checkout/portal/webhook.
let stripe;
let billing;
try {
  billing = loadBillingConfig();
  stripe = createStripeClient(billing.secretKey);
} catch (err) {
  billing = undefined;
  stripe = undefined;
}

// Licensing (entitlement tokens) is optional at boot too: if the Ed25519 env
// isn't set, start without token/auth routes rather than crashing.
let tokenSigner;
try {
  tokenSigner = await createTokenSigner(loadTokenConfig());
} catch (err) {
  tokenSigner = undefined;
}

// Email delivery (magic-link sends) is optional at boot too: if RESEND_API_KEY
// isn't set, start without a sender — magic links are logged instead of sent.
let email;
try {
  email = createResendSender(loadEmailConfig());
} catch (err) {
  email = undefined;
}

const app = buildApp({
  pool,
  stripe,
  billing,
  tokenSigner,
  email,
  corsOrigins: config.corsOrigins,
  logger: { level: config.logLevel },
});

if (!billing) {
  app.log.warn('billing disabled: Stripe env not fully configured (set STRIPE_* to enable checkout/webhook)');
}

if (!tokenSigner) {
  app.log.warn('licensing disabled: entitlement keys not set (set ENTITLEMENT_ED25519_* to enable /v1/token, /v1/auth/*)');
}

if (!email) app.log.warn('email delivery disabled: RESEND_API_KEY not set (magic links log only)');

async function start(): Promise<void> {
  const applied = await runMigrations(pool);
  if (applied.length) app.log.info({ applied }, 'applied migrations');

  await app.listen({ port: config.port, host: config.host });

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
