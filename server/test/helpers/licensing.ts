import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import type Stripe from 'stripe';
import { generateKeyPair, exportPKCS8, exportSPKI } from 'jose';
import { loadTokenConfig } from '../../src/tokens/config.js';
import { createTokenSigner, type TokenSigner } from '../../src/tokens/signer.js';
import type { BillingConfig } from '../../src/billing/config.js';
import { buildApp } from '../../src/app.js';

export async function makeTestSigner(): Promise<TokenSigner> {
  const { publicKey, privateKey } = await generateKeyPair('EdDSA', { crv: 'Ed25519', extractable: true });
  return createTokenSigner(loadTokenConfig({
    ENTITLEMENT_ED25519_PRIVATE_KEY: Buffer.from(await exportPKCS8(privateKey)).toString('base64'),
    ENTITLEMENT_ED25519_PUBLIC_KEY: Buffer.from(await exportSPKI(publicKey)).toString('base64'),
    ENTITLEMENT_ISSUER: 'https://api.slipreel.test',
    ENTITLEMENT_TOKEN_TTL_DAYS: '14',
  }));
}

const billing: BillingConfig = {
  secretKey: 'sk_test_dummy', webhookSecret: 'whsec_x',
  prices: { monthly: 'price_m', yearly: 'price_y', onetime: 'price_o' },
  successUrl: 'https://slipreel.app/success', cancelUrl: 'https://slipreel.app/pricing',
  portalReturnUrl: 'https://slipreel.app/account',
};

/**
 * Build a licensing-enabled app with a fresh signer and a fake Stripe whose
 * checkout.sessions.retrieve is controllable. `stripeState.session` is what
 * retrieve() returns; tests set it per case.
 */
export async function makeLicensingApp(
  pool: pg.Pool,
  opts: { session?: unknown } = {},
): Promise<{ app: FastifyInstance; signer: TokenSigner; stripeState: { session: unknown } }> {
  const signer = await makeTestSigner();
  const stripeState: { session: unknown } = { session: opts.session ?? null };
  const stripe = {
    checkout: { sessions: { retrieve: async (_id: string) => stripeState.session } },
  } as unknown as Stripe;
  const app = buildApp({ pool, stripe, billing, tokenSigner: signer, logger: false });
  await app.ready();
  return { app, signer, stripeState };
}
