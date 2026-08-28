/**
 * One-time (idempotent) creation of Slipreel's Stripe TEST-mode products and
 * prices. Run with your test secret key set:
 *   STRIPE_SECRET_KEY=sk_test_... npm run stripe:bootstrap
 * It prints the three price ids to paste into server/.env. Safe to re-run:
 * it looks up prices by lookup_key and only creates missing ones.
 *
 * Placeholder amounts (USD) — adjust before go-live:
 *   monthly 900 ($9), yearly 7900 ($79), one-time 9900 ($99).
 */
import Stripe from 'stripe';

const key = process.env.STRIPE_SECRET_KEY;
if (!key || !key.startsWith('sk_test_')) {
  console.error('Set STRIPE_SECRET_KEY to a sk_test_ key first (test mode only).');
  process.exit(1);
}
const stripe = new Stripe(key);

type Spec = {
  lookupKey: string;
  productName: string;
  amount: number;
  recurring?: 'month' | 'year';
};

const specs: Spec[] = [
  { lookupKey: 'slipreel_monthly', productName: 'Slipreel Pro (Monthly)', amount: 900, recurring: 'month' },
  { lookupKey: 'slipreel_yearly', productName: 'Slipreel Pro (Yearly)', amount: 7900, recurring: 'year' },
  { lookupKey: 'slipreel_onetime', productName: 'Slipreel Pro (One-time, 1 year of updates)', amount: 9900 },
];

async function ensurePrice(spec: Spec): Promise<string> {
  const existing = await stripe.prices.list({ lookup_keys: [spec.lookupKey], limit: 1 });
  if (existing.data.length > 0) return existing.data[0]!.id;

  const product = await stripe.products.create({ name: spec.productName });
  const price = await stripe.prices.create({
    product: product.id,
    unit_amount: spec.amount,
    currency: 'usd',
    lookup_key: spec.lookupKey,
    ...(spec.recurring ? { recurring: { interval: spec.recurring } } : {}),
  });
  return price.id;
}

const monthly = await ensurePrice(specs[0]!);
const yearly = await ensurePrice(specs[1]!);
const onetime = await ensurePrice(specs[2]!);

console.log('Add these to server/.env (test mode):');
console.log(`STRIPE_PRICE_MONTHLY=${monthly}`);
console.log(`STRIPE_PRICE_YEARLY=${yearly}`);
console.log(`STRIPE_PRICE_ONETIME=${onetime}`);
