import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { findOrCreateUserByEmail } from '../billing/customers.js';

const checkoutBody = z.object({
  email: z.string().email(),
  plan: z.enum(['monthly', 'yearly', 'onetime']),
  device: z.string().optional(),
  device_name: z.string().optional(),
  state: z.string().optional(),
});
const portalBody = z.object({ email: z.string().email() });

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
    });
    return reply.send({ url: session.url });
  });

  // NOTE: email-keyed for this phase; a later auth phase scopes this to the
  // authenticated user instead of trusting a posted email.
  app.post('/v1/portal', async (req, reply) => {
    const parsed = portalBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'invalid request' });
    }
    const { rows } = await app.pool.query<{ stripe_customer_id: string | null }>(
      'SELECT stripe_customer_id FROM users WHERE email = $1',
      [parsed.data.email],
    );
    const customer = rows[0]?.stripe_customer_id;
    if (!customer) return reply.code(404).send({ error: 'no customer for email' });
    const session = await app.stripe.billingPortal.sessions.create({
      customer,
      return_url: app.billing.portalReturnUrl,
    });
    return reply.send({ url: session.url });
  });
}
