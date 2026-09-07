export function checkoutPlan(params) {
  const plan = params.get('plan');
  return ['monthly', 'onetime'].includes(plan) ? plan : 'onetime';
}
