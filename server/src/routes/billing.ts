import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { randomUUID } from 'node:crypto';
import { findOrCreateUserByEmail } from '../billing/customers.js';
import { requireSession } from '../auth/require_session.js';

const checkoutBody = z.object({
  email: z.string().email().optional(),
  // Yearly remains supported for existing subscriptions, not new checkout.
  plan: z.enum(['monthly', 'onetime']),
  device: z.string().max(200).optional(),
  device_name: z.string().max(120).optional(),
  state: z.string().max(200).optional(),
});

export async function billingRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/checkout', { preHandler: requireSession(app), config: { rateLimit: { max: 20, timeWindow: '1 minute' } } }, async (req, reply) => {
    const parsed = checkoutBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'invalid request', detail: parsed.error.issues });
    }
    const { plan } = parsed.data;
    const { rows } = await app.pool.query<{email: string; email_verified: boolean}>('SELECT email, email_verified FROM users WHERE id = $1', [req.userId!]);
    if (!rows[0]?.email_verified) return reply.code(403).send({error: 'email_verification_required'});
    const email = rows[0].email;
    const { stripeCustomerId } = await findOrCreateUserByEmail(app.pool, app.stripe, email);
    const price = app.billing.prices[plan];
    const mode = plan === 'onetime' ? 'payment' : 'subscription';
    const metadata: Record<string, string> = {};
    if (parsed.data.device) metadata.device = parsed.data.device;
    if (parsed.data.device_name) metadata.device_name = parsed.data.device_name;
    if (parsed.data.state) metadata.state = parsed.data.state;
    const flow = randomUUID();
    await app.pool.query('INSERT INTO checkout_flows (id, user_id, context) VALUES ($1,$2,$3)', [flow, req.userId!, JSON.stringify({plan, ...metadata})]);
    metadata.flow = flow;
    const cancel = new URL(app.billing.cancelUrl);
    cancel.searchParams.set('flow', flow);
    const session = await app.stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      mode,
      line_items: [{ price, quantity: 1 }],
      success_url: app.billing.successUrl,
      cancel_url: cancel.toString(),
      metadata,
      // Opt out of Stripe Managed Payments (we don't use Stripe Tax); otherwise
      // accounts with Managed Payments on by default reject checkout unless every
      // product carries a tax_code.
      managed_payments: { enabled: false },
    } as Parameters<typeof app.stripe.checkout.sessions.create>[0]);
    return reply.send({ url: session.url });
  });

  app.get<{Params: {id: string}}>('/v1/checkout-context/:id', {preHandler: requireSession(app)}, async (req, reply) => {
    const {rows} = await app.pool.query("SELECT context FROM checkout_flows WHERE id = $1 AND user_id = $2 AND created_at > now() - interval '30 days'", [req.params.id, req.userId!]);
    return rows[0] ? reply.send(rows[0].context) : reply.code(404).send({error: 'checkout context expired'});
  });

  // Session-scoped: opens the billing portal for the logged-in user only.
  // (Never trust a posted email here — that would let anyone open any
  // customer's portal.)
  app.post('/v1/portal', { preHandler: requireSession(app) }, async (req, reply) => {
    const { rows } = await app.pool.query<{ stripe_customer_id: string | null }>(
      'SELECT stripe_customer_id FROM users WHERE id = $1',
      [req.userId!],
    );
    const customer = rows[0]?.stripe_customer_id;
    if (!customer) return reply.code(404).send({ error: 'no billing account' });
    const session = await app.stripe.billingPortal.sessions.create({
      customer,
      return_url: app.billing.portalReturnUrl,
    });
    return reply.send({ url: session.url });
  });
}
