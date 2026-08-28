import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { findOrCreateUserByEmail } from '../billing/customers.js';
import { requireSession } from '../auth/require_session.js';

const checkoutBody = z.object({
  email: z.string().email(),
  plan: z.enum(['monthly', 'yearly', 'onetime']),
  device: z.string().max(200).optional(),
  device_name: z.string().max(120).optional(),
  state: z.string().max(200).optional(),
});

export async function billingRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/checkout', { config: { rateLimit: { max: 20, timeWindow: '1 minute' } } }, async (req, reply) => {
    const parsed = checkoutBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'invalid request', detail: parsed.error.issues });
    }
    const { email, plan } = parsed.data;
    const { stripeCustomerId } = await findOrCreateUserByEmail(app.pool, app.stripe, email);
    const price = app.billing.prices[plan];
    const mode = plan === 'onetime' ? 'payment' : 'subscription';
    const metadata: Record<string, string> = {};
    if (parsed.data.device) metadata.device = parsed.data.device;
    if (parsed.data.device_name) metadata.device_name = parsed.data.device_name;
    if (parsed.data.state) metadata.state = parsed.data.state;
    const session = await app.stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      mode,
      line_items: [{ price, quantity: 1 }],
      success_url: app.billing.successUrl,
      cancel_url: app.billing.cancelUrl,
      metadata,
      // Opt out of Stripe Managed Payments (we don't use Stripe Tax); otherwise
      // accounts with Managed Payments on by default reject checkout unless every
      // product carries a tax_code.
      managed_payments: { enabled: false },
    } as Parameters<typeof app.stripe.checkout.sessions.create>[0]);
    return reply.send({ url: session.url });
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
