import {beforeAll,afterAll,beforeEach,describe,it,expect} from 'vitest';
import type pg from 'pg';
import type Stripe from 'stripe';
import {testPool,resetDatabase} from './helpers/testDb.js';
import {runMigrations} from '../src/migrate.js';
import {handleStripeEvent} from '../src/billing/entitlements.js';
import {resolveEffectiveEntitlement} from '../src/billing/effective_entitlement.js';
import {makeLicensingApp} from './helpers/licensing.js';
import {registerDevice} from '../src/auth/devices.js';
const event = (id:string,type:string,object:unknown,created=0) => ({id,type,created,data:{object}} as Stripe.Event);
const paid = (pi:string) => ({id:`cs_${pi}`,mode:'payment',payment_status:'paid',customer:'cus',payment_intent:pi});
describe('release security regressions',()=>{
 let pool:pg.Pool;
 beforeAll(async()=>{pool=testPool();await resetDatabase(pool);await runMigrations(pool)});
 afterAll(async()=>{await pool.end()});
 beforeEach(async()=>{await pool.query('DELETE FROM users');await pool.query('DELETE FROM processed_stripe_events');await pool.query('DELETE FROM disputed_payments');await pool.query("INSERT INTO users(id,email,stripe_customer_id) VALUES('u','u@example.com','cus')")});
 it('allows only two seats under concurrent connections and one row for repeated fingerprints',async()=>{
  const results=await Promise.all(Array.from({length:12},(_,i)=>registerDevice(pool,'u',`fp${i}`,null,2)));
  expect(results.filter(r=>r.ok)).toHaveLength(2);
  await pool.query('DELETE FROM devices');
  const repeated=await Promise.all(Array.from({length:8},()=>registerDevice(pool,'u','same',null,2)));
  expect(repeated.every(r=>r.ok)).toBe(true);
  expect((await pool.query('SELECT * FROM devices')).rows).toHaveLength(1);
 });
 it('unpaid completion grants nothing; async success and duplicate event IDs grant only one year',async()=>{
  await handleStripeEvent(pool,event('a','checkout.session.completed',{...paid('pi'),payment_status:'unpaid'}));
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
  await handleStripeEvent(pool,event('b','checkout.session.async_payment_succeeded',paid('pi')));
  await handleStripeEvent(pool,event('c','checkout.session.completed',paid('pi')));
  const eff=await resolveEffectiveEntitlement(pool,'u');
  expect(eff.export).toBe(true); expect(new Date(eff.updatesUntil!).getTime()-Date.now()).toBeLessThan(367*86400000);
 });
 it('refund before fulfillment stays revoked and partial refund cannot clear an open dispute',async()=>{
  let charge={id:'ch',payment_intent:'pi',amount:100,amount_refunded:100,refunded:true,invoice:null};
  const stripe={charges:{retrieve:async()=>charge},disputes:{retrieve:async()=>({status:'needs_response'})}} as unknown as Stripe;
  await handleStripeEvent(pool,event('earlyRefund','charge.refunded',{id:'ch'}),stripe);
  await handleStripeEvent(pool,event('latePaid','checkout.session.completed',paid('pi')));
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
  charge={...charge,payment_intent:'pi_open',amount_refunded:0,refunded:false};
  await handleStripeEvent(pool,event('earlyDispute','charge.dispute.created',{id:'dp',charge:'ch'}),stripe);
  await handleStripeEvent(pool,event('paidOpen','checkout.session.completed',paid('pi_open')));
  charge.amount_refunded=20;
  await handleStripeEvent(pool,event('partialOpen','charge.refunded',{id:'ch'}),stripe);
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
 });
 it('uses current Stripe subscription state when an old delivery arrives',async()=>{
  const current={id:'sub',customer:'cus',status:'canceled',current_period_end:Date.now()/1000+86400};
  const stripe={subscriptions:{retrieve:async()=>current}} as unknown as Stripe;
  await handleStripeEvent(pool,event('stale','customer.subscription.updated',{...current,status:'active'},100),stripe);
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
 });
 it('blocks readiness and retries legacy refunds until history is reconciled',async()=>{
  await pool.query("INSERT INTO purchase_grants(payment_intent_id,user_id,legacy_until) VALUES('legacy_pi','u',now()+interval '2 years')");
  const {app}=await makeLicensingApp(pool,{email:{sendMagicLink:async()=>({id:'test'})}});
  const res=await app.inject({method:'GET',url:'/ready'});
  expect(res.statusCode).toBe(503);expect(res.json().reason).toBe('legacy_purchase_reconciliation_required');
  const stripe={charges:{retrieve:async()=>({id:'ch',payment_intent:'legacy_pi',amount:100,amount_refunded:100,refunded:true,invoice:null})}} as unknown as Stripe;
  await expect(handleStripeEvent(pool,event('legacy_refund','charge.refunded',{id:'ch'}),stripe)).rejects.toThrow('Legacy purchase history');
  expect((await pool.query("SELECT * FROM processed_stripe_events WHERE event_id='legacy_refund'")).rows).toHaveLength(0);
  expect((await pool.query("SELECT revoked FROM purchase_grants WHERE payment_intent_id='legacy_pi'")).rows[0].revoked).toBe(false);
  await app.close();
 });
 it('older subscription snapshots cannot reactivate canceled entitlement',async()=>{
  const sub={id:'sub',customer:'cus',status:'canceled',current_period_end:Date.now()/1000+86400};
  await handleStripeEvent(pool,event('new','customer.subscription.deleted',sub,200));
  await handleStripeEvent(pool,event('old','customer.subscription.updated',{...sub,status:'active'},100));
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
 });
 it('late delivery cannot start a fresh grace period after invoice deadline',async()=>{
  await handleStripeEvent(pool,event('lateGrace','customer.subscription.updated',{id:'sub',customer:'cus',status:'past_due',current_period_start:Date.now()/1000-20*86400,current_period_end:Date.now()/1000+10*86400}));
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
 });
 it('repeated past_due events do not extend grace and expired active periods stop export',async()=>{
  const sub={id:'sub',customer:'cus',status:'past_due',current_period_end:Date.now()/1000+86400};
  await handleStripeEvent(pool,event('g1','customer.subscription.updated',sub,100));
  await pool.query("UPDATE entitlements SET grace_until = now() - interval '1 minute'");
  await handleStripeEvent(pool,event('g2','customer.subscription.updated',sub,101));
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
  await handleStripeEvent(pool,event('g3','customer.subscription.updated',{...sub,status:'active',current_period_end:Date.now()/1000-1},102));
  expect((await resolveEffectiveEntitlement(pool,'u')).export).toBe(false);
 });
 it('refunds and disputes affect their own purchase; partial refunds retain access',async()=>{
  await handleStripeEvent(pool,event('buy1','checkout.session.completed',paid('pi1')));
  await handleStripeEvent(pool,event('buy2','checkout.session.completed',paid('pi2')));
  let charge={id:'ch',payment_intent:'pi2',amount:100,amount_refunded:20,refunded:false,invoice:null};
  let dispute={status:'needs_response'};
  const stripe={charges:{retrieve:async()=>charge},disputes:{retrieve:async()=>dispute}} as unknown as Stripe;
  const prior=(await resolveEffectiveEntitlement(pool,'u')).updatesUntil;
  await handleStripeEvent(pool,event('refundPartial','charge.refunded',{id:'ch'}),stripe);
  expect((await resolveEffectiveEntitlement(pool,'u')).updatesUntil).toBe(prior);
  await handleStripeEvent(pool,event('dispute','charge.dispute.created',{id:'dp',charge:'ch'}),stripe);
  const remaining=await resolveEffectiveEntitlement(pool,'u');expect(remaining.export).toBe(true);expect(remaining.updatesUntil).not.toBe(prior);
  dispute={status:'won'};
  await handleStripeEvent(pool,event('won','charge.dispute.closed',{id:'dp',charge:'ch'}),stripe);
  expect((await resolveEffectiveEntitlement(pool,'u')).updatesUntil).toBe(prior);
  charge={...charge,amount_refunded:100,refunded:true};
  await handleStripeEvent(pool,event('full','charge.refunded',{id:'ch'}),stripe);
  expect((await resolveEffectiveEntitlement(pool,'u')).updatesUntil).toBe(remaining.updatesUntil);
 });
});
