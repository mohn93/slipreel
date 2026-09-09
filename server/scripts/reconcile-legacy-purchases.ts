/** Read Stripe history and print a proposal. Mutates DB only with --apply. */
import pg from 'pg';
import {validateLegacyCoverage,validateReplacementCeilings} from '../src/billing/legacy_reconciliation.js';
import {loadBillingConfig} from '../src/billing/config.js';
import {createStripeClient} from '../src/billing/stripe.js';
import {isExpectedCheckout,recomputeOnetime} from '../src/billing/entitlements.js';

const args = process.argv.slice(2);
const value = (flag:string) => {const at=args.indexOf(flag);return at<0?undefined:args[at+1]};
const historicalPrices = args.flatMap((arg,i)=>arg==='--historical-price' && args[i+1] ? [args[i+1]!] : []);
if (historicalPrices.some(price=>!price.startsWith('price_'))) throw new Error('Historical prices must be explicitly verified Stripe price IDs');
const userId = args[args.indexOf('--user') + 1];
if (!args.includes('--user') || !userId || userId.startsWith('--')) throw new Error('Usage: npm run reconcile:legacy -- --user USER_ID [--apply]');
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
const billing = loadBillingConfig();
const stripe = createStripeClient(billing.secretKey);
const pool = new pg.Pool({connectionString: process.env.DATABASE_URL});
try {
  const {rows} = await pool.query<{stripe_customer_id:string}>('SELECT stripe_customer_id FROM users WHERE id=$1',[userId]);
  const customer = rows[0]?.stripe_customer_id;
  if (!customer) throw new Error('User has no Stripe customer');
  const grants: {pi:string;purchasedAt:Date;revoked:boolean;suspended:boolean}[] = [];
  for await (const session of stripe.checkout.sessions.list({customer,limit:100})) {
    if (session.mode !== 'payment' || session.payment_status !== 'paid' || session.status !== 'complete') continue;
    if (!(await isExpectedCheckout(stripe,billing,session,historicalPrices))) continue;
    const pi = typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id;
    if (!pi || grants.some(g=>g.pi===pi)) continue;
    const intent = await stripe.paymentIntents.retrieve(pi);
    const chargeId = typeof intent.latest_charge === 'string' ? intent.latest_charge : intent.latest_charge?.id;
    if (!chargeId) throw new Error(`No settled charge for ${pi}`);
    const charge = await stripe.charges.retrieve(chargeId);
    const disputes = await stripe.disputes.list({charge:chargeId,limit:100});
    if (disputes.has_more) throw new Error('Unexpected dispute pagination; review manually');
    grants.push({pi,purchasedAt:new Date(session.created*1000),revoked:charge.refunded || disputes.data.some(d=>d.status==='lost'),suspended:disputes.data.some(d=>!['won','lost','warning_closed'].includes(d.status))});
  }
  if (!grants.length) throw new Error('No matching settled purchase history; refusing to erase existing rights');
  const existing = await pool.query('SELECT payment_intent_id,legacy_until FROM purchase_grants WHERE user_id=$1',[userId]);
  validateLegacyCoverage(existing.rows,grants.map(g=>g.pi));
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    for (const grant of [...grants].sort((a,b)=>a.pi.localeCompare(b.pi))) await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[grant.pi]);
    await client.query('SELECT id FROM users WHERE id=$1 FOR UPDATE',[userId]);
    const lockedExisting = await client.query('SELECT payment_intent_id,legacy_until FROM purchase_grants WHERE user_id=$1',[userId]);
    const replacesPlaceholder = validateLegacyCoverage(lockedExisting.rows,grants.map(g=>g.pi));
    // Re-read reversal state while holding the same locks as webhook fulfillment.
    for (const grant of grants) {
      const intent = await stripe.paymentIntents.retrieve(grant.pi);
      const chargeId = typeof intent.latest_charge === 'string' ? intent.latest_charge : intent.latest_charge?.id;
      if (!chargeId) throw new Error('Missing charge during reconciliation');
      const charge = await stripe.charges.retrieve(chargeId);
      const disputes = await stripe.disputes.list({charge:chargeId,limit:100});
      if (disputes.has_more) throw new Error('Unexpected dispute pagination');
      grant.revoked = charge.refunded || disputes.data.some(d=>d.status==='lost');
      grant.suspended = disputes.data.some(d=>!['won','lost','warning_closed'].includes(d.status));
    }
    const before = (await client.query('SELECT updates_until,status FROM entitlements WHERE user_id=$1 AND plan=\'onetime\'',[userId])).rows;
    await client.query('DELETE FROM purchase_grants WHERE user_id=$1',[userId]);
    for (const grant of grants) {
      await client.query(`INSERT INTO purchase_grants(payment_intent_id,user_id,purchased_at,revoked,suspended)
        VALUES($1,$2,$3,$4,$5)`,[grant.pi,userId,grant.purchasedAt,grant.revoked,grant.suspended]);
    }
    await recomputeOnetime(client,userId);
    const after = (await client.query('SELECT updates_until,status FROM entitlements WHERE user_id=$1 AND plan=\'onetime\'',[userId])).rows;
    console.log(JSON.stringify({userId,replacesPlaceholder,historicalPrices,mode:args.includes('--apply')?'apply':'dry_run',before,after,grants},null,2));
    if (args.includes('--apply') && replacesPlaceholder) validateReplacementCeilings(before[0]?.updates_until ?? null,after[0]?.updates_until ?? null,value('--expected-current-until'),value('--expected-reconciled-until'));
    await client.query(args.includes('--apply')?'COMMIT':'ROLLBACK');
  } catch(err) {await client.query('ROLLBACK');throw err;} finally {client.release()}
} finally {await pool.end()}
