import type { FastifyInstance } from 'fastify';
import { handleStripeEvent } from '../billing/entitlements.js';

export async function stripeWebhookRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    '/v1/stripe/webhook',
    { config: { rawBody: true } },
    async (req, reply) => {
      const sig = req.headers['stripe-signature'];
      if (typeof sig !== 'string' || typeof req.rawBody !== 'string') {
        return reply.code(400).send({ error: 'missing signature or body' });
      }
      let evt;
      try {
        evt = app.stripe.webhooks.constructEvent(req.rawBody, sig, app.billing.webhookSecret);
      } catch (err) {
        app.log.warn({ err }, 'stripe webhook signature verification failed');
        return reply.code(400).send({ error: 'invalid signature' });
      }
      try {
        await handleStripeEvent(app.pool, evt);
      } catch (err) {
        app.log.error({ err, type: evt.type }, 'stripe webhook handler failed');
        return reply.code(500).send({ error: 'handler error' });
      }
      return reply.code(200).send({ received: true });
    },
  );
}
