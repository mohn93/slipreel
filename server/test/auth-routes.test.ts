import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';
import {handleStripeEvent} from '../src/billing/entitlements.js';
import type Stripe from 'stripe';
import { createSession } from '../src/auth/sessions.js';

describe('verified checkout completion', () => {
  let pool: pg.Pool;
  let cookie: string;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM users'); await pool.query('DELETE FROM processed_stripe_events'); await pool.query('DELETE FROM failed_checkouts');
    await pool.query("INSERT INTO users (id,email,stripe_customer_id,email_verified) VALUES ('u_c','c@e.com','cus_c',true)");
    cookie = `slipreel_session=${(await createSession(pool,'u_c')).token}`;
  });
  it('never turns a leaked checkout ID into a login', async () => {
    const {app} = await makeLicensingApp(pool,{session:{status:'complete',customer:'cus_c'}});
    const res = await app.inject({method:'POST',url:'/v1/auth/session-from-checkout',payload:{checkout_session_id:'cs_leaked'}});
    expect(res.statusCode).toBe(401); expect(res.headers['set-cookie']).toBeUndefined(); await app.close();
  });
  it('rejects another customer even with a verified session', async () => {
    const {app} = await makeLicensingApp(pool,{session:{status:'complete',customer:'cus_victim'}});
    const res = await app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:'cs_victim'}});
    expect(res.statusCode).toBe(403); await app.close();
  });
  it('pending payments can be retried without consuming activation and fulfill once before webhook', async () => {
    const session = {id:'cs_1',status:'complete',mode:'payment',payment_status:'unpaid',payment_intent:'pi_1',customer:'cus_c',metadata:{device:'fp',state:'nonce'}};
    const {app} = await makeLicensingApp(pool,{session});
    const request = () => app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:'cs_1'}});
    expect((await request()).statusCode).toBe(202);
    session.payment_status = 'paid';
    const first = await request(); expect(first.statusCode).toBe(200); expect(first.json()).toMatchObject({device:'fp',state:'nonce'});
    expect(first.headers['set-cookie']).toBeUndefined(); expect((await request()).statusCode).toBe(200);
    expect((await pool.query('SELECT * FROM purchase_grants')).rows).toHaveLength(1); await app.close();
  });
  it('returns terminal failures, but a later settled payment can still recover', async () => {
    const session = {id:'cs_fail',status:'complete',mode:'payment',payment_status:'unpaid',payment_intent:'pi_fail',customer:'cus_c'};
    const {app}=await makeLicensingApp(pool,{session});
    await handleStripeEvent(pool,{id:'failed_event',type:'checkout.session.async_payment_failed',data:{object:session}} as Stripe.Event);
    const request=()=>app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:session.id}});
    expect((await request()).statusCode).toBe(402);
    session.payment_status='paid';expect((await request()).statusCode).toBe(200);
    session.status='expired';expect((await request()).statusCode).toBe(410);
    await app.close();
  });
  it.each(['paid', 'no_payment_required'])('activates a zero-total order with %s status once, including recovery after an old no-op event', async (payment_status) => {
    const session = {id:'cs_free',status:'complete',mode:'payment',payment_status,amount_total:0,payment_intent:null,customer:'cus_c',created:Math.floor(Date.now()/1000)};
    const {app}=await makeLicensingApp(pool,{session});
    await pool.query("INSERT INTO processed_stripe_events (event_id) VALUES ('checkout_reconcile_cs_free')");
    const request=()=>app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:session.id}});
    expect((await request()).statusCode).toBe(200);
    const first=(await pool.query('SELECT updates_until FROM entitlements')).rows[0].updates_until;
    await handleStripeEvent(pool,{id:'evt_free',type:'checkout.session.completed',data:{object:session}} as Stripe.Event,app.stripe,app.billing);
    expect((await request()).statusCode).toBe(200);
    expect((await pool.query('SELECT * FROM purchase_grants')).rows).toHaveLength(1);
    expect((await pool.query('SELECT updates_until FROM entitlements')).rows[0].updates_until).toEqual(first);
    expect((first.getTime()-session.created*1000)/86400000).toBeGreaterThan(364);
    expect((first.getTime()-session.created*1000)/86400000).toBeLessThan(367);
    await app.close();
  });
  it('fulfills a free-order webhook before success-page activation without duplicate grants', async () => {
    const session={id:'cs_free_hook',status:'complete',mode:'payment',payment_status:'no_payment_required',amount_total:0,payment_intent:null,customer:'cus_c'};
    const {app}=await makeLicensingApp(pool,{session});
    await handleStripeEvent(pool,{id:'evt_free_first',type:'checkout.session.completed',data:{object:session}} as Stripe.Event,app.stripe,app.billing);
    expect((await pool.query('SELECT * FROM purchase_grants')).rows).toHaveLength(1);
    expect((await app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:session.id}})).statusCode).toBe(200);
    expect((await pool.query('SELECT * FROM purchase_grants')).rows).toHaveLength(1);
    await app.close();
  });
  it.each([
    {status:'complete',payment_status:'unpaid',amount_total:0},
    {status:'open',payment_status:'paid',amount_total:0},
    {status:'complete',payment_status:'paid',amount_total:6900},
    {status:'complete',payment_status:'no_payment_required',amount_total:6900},
  ])('does not grant incomplete or unsettled orders without a payment intent: %j', async (fields) => {
    const session={id:'cs_invalid_free',mode:'payment',payment_intent:null,customer:'cus_c',...fields};
    const {app}=await makeLicensingApp(pool,{session});
    expect((await app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:session.id}})).statusCode).not.toBe(200);
    expect((await pool.query('SELECT * FROM purchase_grants')).rows).toHaveLength(0);
    await app.close();
  });
  it('rejects a free checkout for an unrecognized price', async () => {
    const session={id:'cs_other_price',status:'complete',mode:'payment',payment_status:'paid',amount_total:0,payment_intent:null,customer:'cus_c'};
    const {app}=await makeLicensingApp(pool,{session});
    app.stripe.checkout.sessions.listLineItems=async()=>({has_more:false,data:[{quantity:1,price:{id:'price_other'}}]}) as any;
    expect((await app.inject({method:'POST',url:'/v1/auth/session-from-checkout',headers:{cookie},payload:{checkout_session_id:session.id}})).statusCode).toBe(409);
    expect((await pool.query('SELECT * FROM purchase_grants')).rows).toHaveLength(0);
    await app.close();
  });
  it('logout deletes the authenticated session', async () => {
    const {app} = await makeLicensingApp(pool);
    expect((await app.inject({method:'POST',url:'/v1/auth/logout'})).statusCode).toBe(401);
    expect((await app.inject({method:'POST',url:'/v1/auth/logout',headers:{cookie}})).statusCode).toBe(200);
    expect((await app.inject({method:'POST',url:'/v1/auth/logout',headers:{cookie}})).statusCode).toBe(401); await app.close();
  });
});
