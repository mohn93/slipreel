import test from 'node:test';
import assert from 'node:assert/strict';
import { checkoutPlan } from './pricing-plan.js';

test('checkout preserves all valid plan links and defaults invalid links to one-time', () => {
  for (const plan of ['onetime', 'monthly']) {
    assert.equal(checkoutPlan(new URLSearchParams({plan, device:'mac', state:'keep'})), plan);
  }
  for (const query of ['', 'plan=unknown', 'plan=', 'plan=yearly']) {
    assert.equal(checkoutPlan(new URLSearchParams(query)), 'onetime');
  }
});
