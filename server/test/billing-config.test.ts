import { describe, it, expect } from 'vitest';
import { loadBillingConfig } from '../src/billing/config.js';

const base = {
  STRIPE_SECRET_KEY: 'sk_test_x',
  STRIPE_WEBHOOK_SECRET: 'whsec_x',
  STRIPE_PRICE_MONTHLY: 'price_m',
  STRIPE_PRICE_YEARLY: 'price_y',
  STRIPE_PRICE_ONETIME: 'price_o',
};

describe('loadBillingConfig', () => {
  it('parses a valid billing environment and derives URLs from PUBLIC_SITE_URL', () => {
    const cfg = loadBillingConfig({ ...base, PUBLIC_SITE_URL: 'https://slipreel.app' });
    expect(cfg.secretKey).toBe('sk_test_x');
    expect(cfg.webhookSecret).toBe('whsec_x');
    expect(cfg.prices).toEqual({ monthly: 'price_m', yearly: 'price_y', onetime: 'price_o' });
    expect(cfg.successUrl).toBe('https://slipreel.app/success?session_id={CHECKOUT_SESSION_ID}');
    expect(cfg.cancelUrl).toBe('https://slipreel.app/pricing');
    expect(cfg.portalReturnUrl).toBe('https://slipreel.app/account');
  });

  it('defaults PUBLIC_SITE_URL to https://slipreel.app', () => {
    const cfg = loadBillingConfig(base);
    expect(cfg.cancelUrl).toBe('https://slipreel.app/pricing');
  });

  it('throws when a required Stripe var is missing', () => {
    const { STRIPE_WEBHOOK_SECRET, ...missing } = base;
    expect(() => loadBillingConfig(missing)).toThrow(/STRIPE_WEBHOOK_SECRET/);
  });
});
