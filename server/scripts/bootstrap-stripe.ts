/**
 * Idempotent creation of Slipreel's Stripe products and prices in whichever
 * mode the key belongs to. Run with the secret key set:
 *   STRIPE_SECRET_KEY=sk_test_... npm run stripe:bootstrap   # test products
 *   STRIPE_SECRET_KEY=sk_live_... npm run stripe:bootstrap   # LIVE products
 * It prints the three price ids to paste into the env. Safe to re-run: it
 * looks up prices by lookup_key and only creates missing ones.
 *
 * Amounts (USD cents): monthly 1200 ($12), yearly 8900 ($89), one-time 12900
 * ($129). These MUST match the prices shown on the site (pricing.html +
 * index.html). A price's amount is immutable in Stripe — to change a live
 * price, create a new one (new lookup_key) and repoint STRIPE_PRICE_*.
 */
import Stripe from 'stripe';

const key = process.env.STRIPE_SECRET_KEY;
const isTest = !!key && key.startsWith('sk_test_');
const isLive = !!key && key.startsWith('sk_live_');
if (!isTest && !isLive) {
  console.error('Set STRIPE_SECRET_KEY to a sk_test_ or sk_live_ key first.');
  process.exit(1);
}
if (isLive) {
  console.error('LIVE MODE: creating real products/prices on the live account.');
}
const stripe = new Stripe(key!);

type Spec = {
  lookupKey: string;
  productName: string;
  amount: number;
  recurring?: 'month' | 'year';
};

const specs: Spec[] = [
  { lookupKey: 'slipreel_monthly', productName: 'Slipreel Pro (Monthly)', amount: 1200, recurring: 'month' },
  { lookupKey: 'slipreel_yearly', productName: 'Slipreel Pro (Yearly)', amount: 8900, recurring: 'year' },
  { lookupKey: 'slipreel_onetime', productName: 'Slipreel Pro (One-time, 1 year of updates)', amount: 12900 },
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
