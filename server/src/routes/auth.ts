import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { createSession, deleteSession } from '../auth/sessions.js';
import { setSessionCookie, clearSessionCookie, SESSION_COOKIE } from '../auth/cookie.js';
import { requireSession } from '../auth/require_session.js';

const fromCheckout = z.object({ checkout_session_id: z.string().min(1) });

export async function authRoutes(app: FastifyInstance): Promise<void> {
  // Reuse a completed Stripe Checkout session to log the buyer in (no password).
  app.post('/v1/auth/session-from-checkout', async (req, reply) => {
    const parsed = fromCheckout.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const cs = await app.stripe.checkout.sessions.retrieve(parsed.data.checkout_session_id);
    if (cs.status !== 'complete') return reply.code(400).send({ error: 'checkout not complete' });

    const customer = typeof cs.customer === 'string' ? cs.customer : cs.customer?.id;
    if (!customer) return reply.code(400).send({ error: 'no customer on session' });

    const { rows } = await app.pool.query<{ id: string; email: string }>(
      'SELECT id, email FROM users WHERE stripe_customer_id = $1',
      [customer],
    );
    const user = rows[0];
    if (!user) return reply.code(404).send({ error: 'no user for customer' });

    const { token, expiresAt } = await createSession(app.pool, user.id);
    setSessionCookie(reply, token, expiresAt);
    return reply.send({ user: { id: user.id, email: user.email } });
  });

  app.post('/v1/auth/logout', { preHandler: requireSession(app) }, async (req, reply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (token) await deleteSession(app.pool, token);
    clearSessionCookie(reply);
    return reply.send({ ok: true });
  });
}
