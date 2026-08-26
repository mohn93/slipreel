import { z } from 'zod';

const schema = z.object({
  STRIPE_SECRET_KEY: z.string().min(1, 'STRIPE_SECRET_KEY is required'),
  STRIPE_WEBHOOK_SECRET: z.string().min(1, 'STRIPE_WEBHOOK_SECRET is required'),
  STRIPE_PRICE_MONTHLY: z.string().min(1, 'STRIPE_PRICE_MONTHLY is required'),
  STRIPE_PRICE_YEARLY: z.string().min(1, 'STRIPE_PRICE_YEARLY is required'),
  STRIPE_PRICE_ONETIME: z.string().min(1, 'STRIPE_PRICE_ONETIME is required'),
  PUBLIC_SITE_URL: z.string().url().default('https://slipreel.app'),
});

export type BillingConfig = {
  secretKey: string;
  webhookSecret: string;
  prices: { monthly: string; yearly: string; onetime: string };
  successUrl: string;
  cancelUrl: string;
  portalReturnUrl: string;
  siteUrl: string;
};

export function loadBillingConfig(env: NodeJS.ProcessEnv = process.env): BillingConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid billing configuration: ${issues}`);
  }
  const e = parsed.data;
  const site = e.PUBLIC_SITE_URL.replace(/\/$/, '');
  return {
    secretKey: e.STRIPE_SECRET_KEY,
    webhookSecret: e.STRIPE_WEBHOOK_SECRET,
    prices: { monthly: e.STRIPE_PRICE_MONTHLY, yearly: e.STRIPE_PRICE_YEARLY, onetime: e.STRIPE_PRICE_ONETIME },
    successUrl: `${site}/success?session_id={CHECKOUT_SESSION_ID}`,
    cancelUrl: `${site}/pricing`,
    portalReturnUrl: `${site}/account`,
    siteUrl: site,
  };
}
