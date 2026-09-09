import {describe,it,expect} from 'vitest';
import type Stripe from 'stripe';
import type {BillingConfig} from '../src/billing/config.js';
import {validateLegacyCoverage,validateReplacementCeilings} from '../src/billing/legacy_reconciliation.js';
import {isExpectedCheckout} from '../src/billing/entitlements.js';
describe('legacy reconciliation safety',()=>{
 it('allows reviewed synthetic placeholders but never drops a known payment',()=>{
  expect(validateLegacyCoverage([{payment_intent_id:'legacy_ent_1',legacy_until:new Date()}],['pi_real'])).toBe(true);
  expect(()=>validateLegacyCoverage([{payment_intent_id:'pi_old'}],['pi_new'])).toThrow('does not cover');
  expect(()=>validateLegacyCoverage([{payment_intent_id:'legacy_ent_1',legacy_until:new Date()},{payment_intent_id:'pi_old'}],['pi_new'])).toThrow('does not cover');
 });
 it('requires the precise reviewed before and after ceilings for synthetic replacement',()=>{
  const before='2027-09-09T00:00:00.000Z';const after='2027-09-08T23:55:00.000Z';
  expect(()=>validateReplacementCeilings(before,after)).toThrow('requires');
  expect(()=>validateReplacementCeilings(before,after,before,before)).toThrow('requires');
  expect(()=>validateReplacementCeilings(before,after,before,after)).not.toThrow();
  expect(()=>validateReplacementCeilings(before,null,before,'none')).not.toThrow();
 });
 it('accepts current and explicitly approved historical prices, rejecting unrelated products',async()=>{
  let price='price_old';
  const stripe={checkout:{sessions:{listLineItems:async()=>({has_more:false,data:[{quantity:1,price:{id:price}}]})}}} as unknown as Stripe;
  const billing={prices:{onetime:'price_current',monthly:'price_m',yearly:'price_y'}} as BillingConfig;
  const session={id:'cs',mode:'payment'} as Stripe.Checkout.Session;
  expect(await isExpectedCheckout(stripe,billing,session)).toBe(false);
  expect(await isExpectedCheckout(stripe,billing,session,['price_old'])).toBe(true);
  price='price_current';expect(await isExpectedCheckout(stripe,billing,session,['price_old'])).toBe(true);
  price='price_unrelated';expect(await isExpectedCheckout(stripe,billing,session,['price_old'])).toBe(false);
 });
});
